# stop-browser.ps1 — 卸载时关闭 Course-Thru（课速通）启动的浏览器进程
# 按安装目录路径过滤，不会误杀用户自己的 Google Chrome。
$appDir = $PSScriptRoot
Get-Process chrome -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "$appDir\*" } |
    Stop-Process -Force
