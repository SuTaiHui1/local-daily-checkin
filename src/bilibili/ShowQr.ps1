param([Parameter(Mandatory=$true)][string]$StateRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$form=New-Object Windows.Forms.Form
$form.Text='B站扫码登录 — 仅在本机显示'
$form.StartPosition='CenterScreen'
$form.TopMost=$true
$form.ClientSize=[Drawing.Size]::new(620,680)
$label=New-Object Windows.Forms.Label
$label.Text="请使用哔哩哔哩 App 扫码，并在手机上确认登录。`r`n二维码有时效；本窗口会在本次登录结束后自动关闭。"
$label.Dock='Top'; $label.Height=70
$label.Font=[Drawing.Font]::new('Microsoft YaHei',12)
$pic=New-Object Windows.Forms.PictureBox
$pic.Dock='Fill'; $pic.SizeMode='Zoom'
$pic.Image=[Drawing.Image]::FromFile((Join-Path $StateRoot 'login-qr.png'))
$form.Controls.Add($pic); $form.Controls.Add($label)
$timer=New-Object Windows.Forms.Timer
$timer.Interval=1000
$form.Add_Shown({ 'visible' | Set-Content -LiteralPath (Join-Path $StateRoot 'qr-visible.txt'); $form.Activate() })
$timer.Add_Tick({if(Test-Path -LiteralPath (Join-Path $StateRoot 'login.done')){$form.Close()}})
$timer.Start()
$null=$form.ShowDialog()
$timer.Dispose(); $pic.Image.Dispose(); $form.Dispose()
Remove-Item -LiteralPath (Join-Path $StateRoot 'login-qr.png') -ErrorAction SilentlyContinue
