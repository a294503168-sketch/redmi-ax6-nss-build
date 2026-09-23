'use strict';
'require baseclass';
'require rpc';
'require poll';

/* 首页「性能监控」面板：CPU 占用率、NSS 核心占用率、各温度传感器。
 *
 * 首页各分区默认 5 秒刷新一次，这里另起一个 1 秒的轮询，直接改写已渲染的表格，
 * 所以只注册一次全局 poll，靠元素 id 找回表格；分区被上层重绘也不会重复注册。
 */

var callSysperf = rpc.declare({
	object: 'luci.sysperf',
	method: 'stats'
});

var TABLE_ID = 'sysperf-table',
    TEMP_MAX = 110,   /* 温度进度条满刻度，°C */
    TEMP_ROWS = 5;    /* 最多显示几个温度传感器 */

/* 上一次 /proc/stat 采样与算出的占用率，跨轮询保留 */
var lastCPU = {},
    lastPct = {},
    pollStarted = false;

/* 与 20_memory.js 同款进度条：title 会被 LuCI 的样式显示在进度条上 */
function progressbar(pct, title) {
	var v = Math.max(0, Math.min(100, pct || 0));

	return E('div', {
		'class': 'cbi-progressbar',
		'title': title
	}, E('div', { 'style': 'width:%.2f%%'.format(v) }));
}

function row(label, content) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '33%' }, [ label ]),
		E('td', { 'class': 'td left' }, [ content ])
	]);
}

function cpuRows(cpu) {
	var rows = [],
	    now = Date.now();

	/* 只显示总占用，逐核数据后端照样送，需要时把这个过滤去掉即可 */
	(Array.isArray(cpu) ? cpu : []).filter(function(c) {
		return c.name == 'cpu';
	}).forEach(function(c) {
		var busy = Number(c.busy) || 0,
		    idle = Number(c.idle) || 0,
		    prev = lastCPU[c.name],
		    pct = lastPct[c.name];

		/* 首页自己的 5 秒轮询也会调 load()，可能和这里的 1 秒轮询挨着落地。
		 * 间隔太短的采样点差值噪声很大，直接丢掉，基准也不更新。 */
		if (!prev || (now - prev.ts) >= 500) {
			if (prev) {
				var db = busy - prev.busy,
				    dt = db + (idle - prev.idle);

				if (dt > 0)
					pct = 100 * db / dt;
			}

			lastCPU[c.name] = { busy: busy, idle: idle, ts: now };
		}

		if (pct != null)
			lastPct[c.name] = pct;

		rows.push(row(
			(c.name == 'cpu') ? 'CPU 占用率' : 'CPU 核心 %s'.format(c.name.substring(3)),
			(pct == null) ? E('em', {}, '采样中…') : progressbar(pct, '%.1f%%'.format(pct))
		));
	});

	return rows;
}

function nssRows(nss) {
	if (!Array.isArray(nss) || !nss.length)
		return [ row('NSS 占用率', E('em', {}, '不可用')) ];

	/* 这台只报一个核心，不必标号；真出现多核再把编号加回去区分 */
	var single = (nss.length == 1);

	return nss.map(function(n) {
		return row(single ? 'NSS 核心' : 'NSS 核心 %d'.format(n.core),
			progressbar(n.avg, '%d%%'.format(n.avg)));
	});
}

/* ipq807x 的 tsens 有十几路传感器（cpu0-3 / nss0-1 / nss-top / wcss-phy* / cluster），
 * 一路一行太吵，按家族归并成几组，每组取组内最高温。 */
var TEMP_GROUPS = [
	[ /^(cpu|cluster)/, 'CPU 温度' ],
	[ /^nss/,           'NSS 温度' ],
	[ /^(wcss|phy)/,    'WiFi 温度' ]
];

/* q6 / lpass 那几路不是本机主要热源，不显示 */
var TEMP_SKIP = /^(q6|lpass)/;

function tempGroup(name) {
	for (var i = 0; i < TEMP_GROUPS.length; i++)
		if (TEMP_GROUPS[i][0].test(name))
			return TEMP_GROUPS[i][1];

	return '温度 · ' + name;
}

function tempRows(thermal) {
	var sum = {}, count = {};

	(Array.isArray(thermal) ? thermal : []).forEach(function(z) {
		var name = String(z.type || '').replace(/-thermal$/, ''),
		    group;

		if (TEMP_SKIP.test(name))
			return;

		group = tempGroup(name);
		sum[group] = (sum[group] || 0) + Number(z.temp) / 1000;
		count[group] = (count[group] || 0) + 1;
	});

	/* 组内取平均：cpu0-3 四路挨着，单看某一路的瞬时峰值意义不大 */
	var avg = {};
	Object.keys(sum).forEach(function(g) { avg[g] = sum[g] / count[g] });

	var groups = Object.keys(avg).sort(function(a, b) {
		return avg[b] - avg[a];
	});

	if (!groups.length)
		return [ row('温度', E('em', {}, '不可用')) ];

	return groups.slice(0, TEMP_ROWS).map(function(g) {
		return row(g, progressbar(avg[g] / TEMP_MAX * 100, '%.1f °C'.format(avg[g])));
	});
}

function update(table, data) {
	var rows = cpuRows(data.cpu).concat(nssRows(data.nss), tempRows(data.thermal));

	while (table.firstChild)
		table.removeChild(table.firstChild);

	rows.forEach(function(r) { table.appendChild(r) });
}

return baseclass.extend({
	title: '性能监控',

	load: function() {
		return L.resolveDefault(callSysperf(), {});
	},

	render: function(data) {
		var table = E('table', { 'class': 'table', 'id': TABLE_ID });

		update(table, data);

		if (!pollStarted) {
			pollStarted = true;

			poll.add(function() {
				/* 离开首页后表格就没了，此时不必再发请求 */
				if (!document.getElementById(TABLE_ID))
					return Promise.resolve();

				return L.resolveDefault(callSysperf(), {}).then(function(d) {
					var t = document.getElementById(TABLE_ID);
					if (t)
						update(t, d);
				});
			}, 1);
		}

		return table;
	}
});
