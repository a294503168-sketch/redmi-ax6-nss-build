# 精简 zsh 配置（OpenWrt / Redmi AX6）

export LANG=zh_CN.UTF-8
export LC_ALL=zh_CN.UTF-8
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# 历史
HISTFILE=~/.zsh_history
HISTSIZE=5000
SAVEHIST=5000
setopt APPEND_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE SHARE_HISTORY

# 交互行为
setopt AUTO_CD INTERACTIVE_COMMENTS NO_BEEP
unsetopt NOMATCH

# 补全
autoload -Uz compinit && compinit -d ~/.zcompdump
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'

# 提示符：root@主机 当前目录 #
autoload -Uz colors && colors
PROMPT='%F{red}%n%f@%F{green}%m%f %F{blue}%~%f %# '

# 常用别名
alias ll='ls -alh'
alias la='ls -A'
alias l='ls -CF'
alias df='df -h'
alias free='free -m'
alias logread='logread -f'
