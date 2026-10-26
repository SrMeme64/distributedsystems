[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param(
    [string]$ComposeEnvFile = ".env.exam",

    [switch]$UseScheduledTask,

    [string]$TaskName = "Distributed Store Stack",

    [switch]$Remove,

    [switch]$StartNow
)

# Installs (or removes) the automatic start of the stack when the user logs in.
#
# Default: a shortcut in the per-user Startup folder. No administrator rights.
# -UseScheduledTask: a Task Scheduler entry at logon (also per-user).
#
# Docker Desktop must be configured to start when you sign in. Start-Stack.ps1
# waits for the daemon anyway, so it also works if Docker starts a bit later.

$repositoryRoot = $PSScriptRoot
$startScript = Join-Path $repositoryRoot "Start-Stack.ps1"
$logPath = Join-Path $repositoryRoot "PoCs\evidencias\start-stack.log"
$startupFolder = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupFolder "Distributed Store Stack.lnk"

if (-not (Test-Path -LiteralPath $startScript -PathType Leaf)) {
    throw "No se encontro $startScript"
}

$arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ComposeEnvFile "{1}" -LogPath "{2}"' -f `
    $startScript, $ComposeEnvFile, $logPath

if ($Remove) {
    if (Test-Path -LiteralPath $shortcutPath) {
        if ($PSCmdlet.ShouldProcess($shortcutPath, "Eliminar acceso de inicio automatico")) {
            Remove-Item -LiteralPath $shortcutPath -Force
            Write-Output "Acceso de inicio eliminado: $shortcutPath"
        }
    } else {
        Write-Output "No existe el acceso de inicio: $shortcutPath"
    }

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        if ($PSCmdlet.ShouldProcess($TaskName, "Eliminar tarea programada")) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Output "Tarea programada eliminada: $TaskName"
        }
    } else {
        Write-Output "No existe la tarea programada: $TaskName"
    }

    return
}

if ($UseScheduledTask) {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments -WorkingDirectory $repositoryRoot
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 20)

    if ($PSCmdlet.ShouldProcess($TaskName, "Registrar tarea programada al iniciar sesion")) {
        try {
            Register-ScheduledTask `
                -TaskName $TaskName `
                -Action $action `
                -Trigger $trigger `
                -Settings $settings `
                -Description "Arranca el stack Docker de la demo al iniciar sesion." `
                -Force | Out-Null
            Write-Output "Tarea programada registrada: $TaskName"
            Write-Output "Log: $logPath"
        } catch {
            Write-Warning "No se pudo registrar la tarea: $($_.Exception.Message)"
            Write-Warning "Se usara el acceso en la carpeta Startup como alternativa."
            $UseScheduledTask = $false
        }
    }
}

if (-not $UseScheduledTask) {
    if ($PSCmdlet.ShouldProcess($shortcutPath, "Crear acceso de inicio automatico")) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = "powershell.exe"
        $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = $repositoryRoot
        $shortcut.WindowStyle = 7
        $shortcut.Description = "Arranca el stack Docker de la demo al iniciar sesion."
        $shortcut.Save()
        Write-Output "Acceso de inicio creado: $shortcutPath"
        Write-Output "Log: $logPath"
    }
}

Write-Output ""
Write-Output "Recomendacion: en Docker Desktop, activa 'Start Docker Desktop when you sign in'."
Write-Output "Para probar ahora: powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-Stack.ps1"

if ($StartNow) {
    Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    Write-Output "Arranque lanzado en segundo plano."
}
