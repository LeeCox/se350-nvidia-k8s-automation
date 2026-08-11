param(
    [string]$BaseUrl = "http://127.0.0.1:8000/v1",
    [string]$Model = "nvidia-nemotron-3-nano-4b-bf16"
)

$ErrorActionPreference = "Stop"
$messages = @()

$tools = @(
    @{
        type = "function"
        function = @{
            name = "get_local_time"
            description = "Return the current local time on the client machine."
            parameters = @{
                type = "object"
                properties = @{}
                required = @()
            }
        }
    }
)

function Invoke-Tool {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Arguments
    )

    if ($Name -ne "get_local_time") {
        throw "Tool '$Name' is not allowed by this client."
    }

    if ($Arguments -and $Arguments -ne "{}") {
        $null = $Arguments | ConvertFrom-Json
    }

    return (Get-Date).ToString("o")
}

function Invoke-Chat {
    param(
        [Parameter(Mandatory)]
        [array]$Conversation
    )

    $request = @{
        model = $Model
        messages = $Conversation
        tools = $tools
        max_tokens = 512
        chat_template_kwargs = @{
            enable_thinking = $false
        }
    } | ConvertTo-Json -Depth 15

    return Invoke-RestMethod `
        -Uri "$BaseUrl/chat/completions" `
        -Method Post `
        -ContentType "application/json" `
        -Body $request
}

Write-Host "Nemotron agent chat. Type 'exit' to quit."
while ($true) {
    $prompt = Read-Host "You"
    if ($prompt -eq "exit") {
        break
    }

    $messages += @{
        role = "user"
        content = $prompt
    }

    while ($true) {
        $response = Invoke-Chat -Conversation $messages
        $assistant = $response.choices[0].message

        $assistantMessage = @{
            role = "assistant"
            content = $assistant.content
        }
        if ($assistant.tool_calls) {
            $assistantMessage.tool_calls = @($assistant.tool_calls)
        }
        $messages += $assistantMessage

        if (-not $assistant.tool_calls) {
            Write-Host "Nemotron: $($assistant.content)"
            break
        }

        foreach ($toolCall in @($assistant.tool_calls)) {
            $toolResult = Invoke-Tool `
                -Name $toolCall.function.name `
                -Arguments $toolCall.function.arguments
            $messages += @{
                role = "tool"
                tool_call_id = $toolCall.id
                content = $toolResult
            }
        }
    }
}