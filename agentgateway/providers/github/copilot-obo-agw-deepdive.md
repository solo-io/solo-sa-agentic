## MCP Tool Selection

## BYOK

BYOK (Bring Your Own Key) allows you to use GitHub Copilots SDK to authenticate via GitHub Copilot with your LLM providers (OpenAI, Anthropic, Gemini, etc.) API key.

[Supported providers as of May, 2026](https://docs.github.com/en/copilot/how-tos/copilot-sdk/authenticate-copilot-sdk/bring-your-own-key)

![](../../images/BYOK.png)

## OBO

### OBO Flow

### Agent Identity With OBO

This also falls under the request for “Agent “Isolation: “if its this agent identity, only allow these MCP Server tools”

Example in the agw policy: `jwt.act.sub == "research-agent" && mcp.tool.name in ["search", "fetch_doc”]`

### OBO Agent/tool isolation for MCP

## Intent-Based Routing

Intent-based routing can be used to specify, for example, users that have access to specific Models.

```
  transformations:
    - field: model
      expression: >
        llm.inputTokens > 8000 ? "claude-sonnet-4-6"
        : (request.headers["x-user-tier"] == "premium" ? "gpt-4o" : "gpt-4o-mini")

```
But thats it, right? Nothing out of the box to say "hide model from this user"

## Routing From GitHub Copilot through agw

- Public models
- Self-hosted models