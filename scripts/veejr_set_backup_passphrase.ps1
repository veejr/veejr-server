[CmdletBinding()]
param(
  [string]$PassphraseFile = "C:\ProgramData\Veejr\backup-keys\google-drive.dpapi"
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security

$Form = New-Object System.Windows.Forms.Form
$Form.Text = "Veejr encrypted backup"
$Form.ClientSize = New-Object System.Drawing.Size(520, 280)
$Form.StartPosition = "CenterScreen"
$Form.FormBorderStyle = "FixedDialog"
$Form.MaximizeBox = $false
$Form.MinimizeBox = $false
$Form.TopMost = $true

$Intro = New-Object System.Windows.Forms.Label
$Intro.Location = New-Object System.Drawing.Point(24, 20)
$Intro.Size = New-Object System.Drawing.Size(470, 64)
$Intro.Text = "Choose a long, unique backup passphrase. Save the same passphrase in your password manager; it is required if this server is ever lost."
$Form.Controls.Add($Intro)

$FirstLabel = New-Object System.Windows.Forms.Label
$FirstLabel.Location = New-Object System.Drawing.Point(24, 94)
$FirstLabel.Size = New-Object System.Drawing.Size(170, 20)
$FirstLabel.Text = "Backup passphrase"
$Form.Controls.Add($FirstLabel)

$FirstBox = New-Object System.Windows.Forms.TextBox
$FirstBox.Location = New-Object System.Drawing.Point(200, 91)
$FirstBox.Size = New-Object System.Drawing.Size(290, 24)
$FirstBox.UseSystemPasswordChar = $true
$Form.Controls.Add($FirstBox)

$SecondLabel = New-Object System.Windows.Forms.Label
$SecondLabel.Location = New-Object System.Drawing.Point(24, 132)
$SecondLabel.Size = New-Object System.Drawing.Size(170, 20)
$SecondLabel.Text = "Confirm passphrase"
$Form.Controls.Add($SecondLabel)

$SecondBox = New-Object System.Windows.Forms.TextBox
$SecondBox.Location = New-Object System.Drawing.Point(200, 129)
$SecondBox.Size = New-Object System.Drawing.Size(290, 24)
$SecondBox.UseSystemPasswordChar = $true
$Form.Controls.Add($SecondBox)

$Status = New-Object System.Windows.Forms.Label
$Status.Location = New-Object System.Drawing.Point(24, 166)
$Status.Size = New-Object System.Drawing.Size(466, 36)
$Status.ForeColor = [System.Drawing.Color]::Firebrick
$Form.Controls.Add($Status)

$Cancel = New-Object System.Windows.Forms.Button
$Cancel.Location = New-Object System.Drawing.Point(310, 220)
$Cancel.Size = New-Object System.Drawing.Size(85, 32)
$Cancel.Text = "Cancel"
$Cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$Form.Controls.Add($Cancel)
$Form.CancelButton = $Cancel

$Save = New-Object System.Windows.Forms.Button
$Save.Location = New-Object System.Drawing.Point(405, 220)
$Save.Size = New-Object System.Drawing.Size(85, 32)
$Save.Text = "Save"
$Form.Controls.Add($Save)
$Form.AcceptButton = $Save

$Save.Add_Click({
  if ($FirstBox.Text.Length -lt 16) {
    $Status.Text = "Use at least 16 characters. A generated multi-word passphrase is recommended."
    return
  }
  if ($FirstBox.Text -cne $SecondBox.Text) {
    $Status.Text = "The passphrases do not match."
    return
  }

  try {
    $Parent = Split-Path -Parent $PassphraseFile
    New-Item -ItemType Directory -Path $Parent -Force | Out-Null
    $PlainBytes = [System.Text.Encoding]::UTF8.GetBytes($FirstBox.Text)
    $Entropy = [System.Text.Encoding]::UTF8.GetBytes("Veejr backup key v1")
    $ProtectedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
      $PlainBytes,
      $Entropy,
      [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    [System.Convert]::ToBase64String($ProtectedBytes) |
      Set-Content -LiteralPath $PassphraseFile -Encoding ASCII
    $Form.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $Form.Close()
  } catch {
    $Status.Text = "Could not save the protected key: $($_.Exception.Message)"
  } finally {
    if ($PlainBytes) { [System.Array]::Clear($PlainBytes, 0, $PlainBytes.Length) }
    if ($ProtectedBytes) { [System.Array]::Clear($ProtectedBytes, 0, $ProtectedBytes.Length) }
  }
})

$Form.Add_Shown({ $FirstBox.Focus() })
$Result = $Form.ShowDialog()
$FirstBox.Text = ""
$SecondBox.Text = ""
$Form.Dispose()

if ($Result -ne [System.Windows.Forms.DialogResult]::OK) {
  throw "Backup-key setup was canceled."
}
