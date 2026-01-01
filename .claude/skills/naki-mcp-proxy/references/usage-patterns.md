# Naki MCP Usage Patterns

Advanced usage patterns and workflows for Naki MCP tools.

---

## Pattern 1: Autonomous Game Session

Complete workflow for automated ranked game play.

```
Phase 1: Setup
├── lobby_status         → Verify in lobby
├── lobby_account_level  → Check current rank
└── lobby_navigate       → Go to ranked (page: 1)

Phase 2: Match
├── lobby_start_match    → Start matching (match_mode: 5)
├── lobby_match_status   → Poll until matched
└── [wait for game start]

Phase 3: Game Loop
├── bot_status           → Get AI recommendation
├── [optional] highlight_tile → Visualize recommendation
├── bot_trigger          → Execute AI action
└── [repeat until game end]

Phase 4: Post-game
├── get_logs            → Review game decisions
└── lobby_status        → Return to lobby
```

---

## Pattern 2: Debug Investigation

When something goes wrong during gameplay.

```
Step 1: State Capture
├── game_state    → Full game context
├── game_hand     → Current hand tiles
├── game_ops      → Available operations
└── bot_status    → AI analysis

Step 2: Log Analysis
├── get_logs      → Recent operations
└── detect        → API availability

Step 3: Manual Intervention
├── execute_js    → Direct game API calls
├── bot_sync      → Force reconnect if needed
└── game_action   → Manual action override
```

---

## Pattern 3: Tile Recommendation Visualization

Show AI recommendations with color coding.

```javascript
// Step 1: Get recommendations from bot_status
{
  "recommendations": [
    {"tile": "5m", "q_value": 0.95, "index": 3},
    {"tile": "2p", "q_value": 0.72, "index": 7},
    {"tile": "N", "q_value": 0.45, "index": 12}
  ]
}

// Step 2: Apply color highlights
// Q-value > 0.8 → green
// Q-value 0.5-0.8 → orange
// Q-value < 0.5 → red

highlight_tile --tileIndex 3 --color green   // Best choice
highlight_tile --tileIndex 7 --color orange  // Alternative
highlight_tile --tileIndex 12 --color red    // Risky

// Step 3: Or use batch highlighting
show_recommendations --recommendations '[
  {"tileIndex": 3, "color": "green"},
  {"tileIndex": 7, "color": "orange"},
  {"tileIndex": 12, "color": "red"}
]'
```

---

## Pattern 4: Anti-Idle Automation

Prevent disconnection during long sessions.

```
Option A: Manual heartbeat
├── lobby_heartbeat   → Send single heartbeat

Option B: Automatic mode
├── lobby_anti_idle --enabled true   → Enable auto heartbeat
├── lobby_idle_status                → Check current status
└── lobby_anti_idle --enabled false  → Disable when done
```

---

## Pattern 5: Emoji Interaction

Social gameplay features.

```
// List available emojis
game_emoji_list → Returns emoji catalog

// Send emoji
game_emoji --emo_id 3 --count 2   → Send 2x emoji #3

// Auto-reply mode
game_emoji_auto_reply --enabled true

// Monitor received emojis
game_emoji_listen --clear false   → Get log without clearing
game_emoji_listen --clear true    → Get and clear log
```

---

## Pattern 6: UI Privacy Mode

Hide player names for streaming/screenshots.

```
// Check current state
ui_names_status → {"visible": true, "count": 4}

// Hide all names
ui_names_hide → All player names hidden

// Toggle on/off
ui_names_toggle → Switch visibility state

// Restore names
ui_names_show → All names visible again
```

---

## Pattern 7: Custom JavaScript Execution

Direct game API manipulation.

```javascript
// Get game manager reference
execute_js --code "return typeof view !== 'undefined'"

// Check hand tiles
execute_js --code "return view.DesktopMgr.Inst.mainrole.hand.length"

// Get current player seat
execute_js --code "return view.DesktopMgr.Inst.mainrole.seat"

// Check dora indicators
execute_js --code "return JSON.stringify(view.DesktopMgr.Inst.dora)"

// Force UI refresh
execute_js --code "view.DesktopMgr.Inst.mainrole.RefreshHand(); return true"
```

**Important**: Always use `return` statement to get results.

---

## Pattern 8: Calibration for Click Automation

Adjust click positions for different screen sizes.

```
// Get current calibration
calibrate → Returns current settings

// Adjust for wide screen
calibrate --tileSpacing 48 --offsetX 5 --offsetY 0

// Test with indicators
test_indicators → Shows calibration overlay

// Verify with single click
click --x 500 --y 700 --label "Test click"
```

---

## Pattern 9: Connection Recovery

Handle disconnection scenarios.

```
// Check connection status
detect → API availability check

// If disconnected:
bot_sync → Force reconnect + rebuild bot state

// Verify recovery
bot_status → Should show active state
game_state → Should have game data
```

---

## Pattern 10: Multi-step Action Verification

Execute action with result validation.

```
// Method A: Action + separate verify
game_action --action "dahai 5m"
game_hand   → Check tile was discarded

// Method B: Combined verify
game_action_verify --action "dahai 5m"
→ Returns success/failure with game state update
```

---

## Error Recovery Strategies

| Scenario | Detection | Recovery |
|----------|-----------|----------|
| API unavailable | `detect` returns false | Wait for game load |
| Bot not active | `bot_status` empty | Wait for `start_game` |
| Wrong game state | `game_state` mismatch | Use `bot_sync` |
| Click miss | Action not executed | Adjust `calibrate` |
| Rate limit | Repeated failures | Add delays between calls |

---

**Last Updated**: 2026-01-01
