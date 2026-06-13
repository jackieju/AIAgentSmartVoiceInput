HANDOFF: Fix Realtime Voice Mode

ROOT CAUSE: SFSpeechRecognizer restarts every ~1 second on "No speech detected", causing menu lag and keyword detection failures.

FIX PLAN:
1. Add exponential backoff on restart (1s -> 2s -> 4s -> max 10s), reset on speech detected
2. Fix toggleRealtimeMode - stop() not releasing resources properly
3. Exit keyword: check each partial result with contains(), trigger immediately
4. Disable auto wake listen (done), keep manual menu entry only

Keywords: trigger=完毕, exit=退出语音, wake=登登同学, reset=不算重来
Files: Sources/RealtimeVoiceMode.swift, Sources/App.swift, inject-helper.swift
Project: /Users/I027910/Desktop/ju/projects/AIAgentSmartVoiceInput
