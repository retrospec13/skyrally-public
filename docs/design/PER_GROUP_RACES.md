# Per-group races

## Per-group readiness
Systems isolate state through race-group slots. Client views route through the local player group; hub and server services are explicitly shared.

| System | Reference |
|---|---|
| `race-state` | See ModeScopeRules.SYSTEMS |
| `bots` | See ModeScopeRules.SYSTEMS |
| `items` | See ModeScopeRules.SYSTEMS |
| `boss-hazards` | See ModeScopeRules.SYSTEMS |
| `boss-intro` | See ModeScopeRules.SYSTEMS |
| `coins` | See ModeScopeRules.SYSTEMS |
| `keys` | See ModeScopeRules.SYSTEMS |
| `ducks` | See ModeScopeRules.SYSTEMS |
| `cannons` | See ModeScopeRules.SYSTEMS |
| `retired-bosses` | See ModeScopeRules.SYSTEMS |
| `vents` | See ModeScopeRules.SYSTEMS |
| `battles` | See ModeScopeRules.SYSTEMS |
| `time-trials` | See ModeScopeRules.SYSTEMS |
| `storm-race-v2` | See ModeScopeRules.SYSTEMS |
| `storm-cup-v1` | See ModeScopeRules.SYSTEMS |
| `hud-attributes` | See ModeScopeRules.SYSTEMS |
| `results-rewards` | See ModeScopeRules.SYSTEMS |
| `portal-queue` | See ModeScopeRules.SYSTEMS |
| `purchase-prompts` | See ModeScopeRules.SYSTEMS |
| `track-load` | See ModeScopeRules.SYSTEMS |

## Streaming trial (steps)
Streaming remains off. In a separate local Studio copy, test two groups on different maps; verify collision, models, route state, respawns and late joins before considering a streaming change. Do not enable streaming in the release project based on headless tests.
