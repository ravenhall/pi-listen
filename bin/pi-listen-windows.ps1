$ErrorActionPreference = "Stop"

function Emit-Frame {
    param(
        [string] $Status,
        [string] $Text
    )

    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        [Console]::Out.WriteLine("$Status`t$Text")
        [Console]::Out.Flush()
    }
}

try {
    Add-Type -AssemblyName System.Speech

    $recognizer = New-Object System.Speech.Recognition.SpeechRecognitionEngine
    $recognizer.SetInputToDefaultAudioDevice()
    $recognizer.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))

    Register-ObjectEvent -InputObject $recognizer -EventName SpeechHypothesized -Action {
        $text = $EventArgs.Result.Text
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            [Console]::Out.WriteLine("streaming`t$text")
            [Console]::Out.Flush()
        }
    } | Out-Null

    Register-ObjectEvent -InputObject $recognizer -EventName SpeechRecognized -Action {
        $text = $EventArgs.Result.Text
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            [Console]::Out.WriteLine("final`t$text")
            [Console]::Out.Flush()
        }
    } | Out-Null

    $recognizer.RecognizeAsync([System.Speech.Recognition.RecognizeMode]::Multiple)

    while ($true) {
        Wait-Event -Timeout 1 | Out-Null
    }
} catch {
    Emit-Frame "error" $_.Exception.Message
    exit 1
} finally {
    if ($recognizer) {
        $recognizer.RecognizeAsyncCancel()
        $recognizer.Dispose()
    }
}
