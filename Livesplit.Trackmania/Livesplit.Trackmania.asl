state("Trackmania") {}

startup {
    settings.Add("track", true, "Split at every track done");
    settings.Add("checkpoint", false, "Split at every checkpoint");

    settings.Add("cStart", false, "Auto-start on every track");
    settings.Add("cTraining", false, "Training individual splits (overridden by \"all tracks/checkpoints\" settings)");
    settings.Add("cSeason", false, "Season individual splits (overridden by \"all tracks/checkpoints\" settings)");

    for (int trackId = 1; trackId < 26; trackId++) {
        string trackNb = trackId.ToString("D2");
        settings.Add("t"+trackNb, true, "Training - "+trackNb, "cTraining");
        settings.Add("s"+trackNb, true, "Season - "+trackNb, "cSeason");
    }

    vars.timerResetVars = (EventHandler)((s, e) => {
        vars.totalGameTime = 0;
        vars.lastCP = Tuple.Create("", 0);
        vars.logTimes = new Dictionary<string, int>();
        vars.startMap = vars.loadMap.Current;
        vars.trackDone = false;
    });
    timer.OnStart += vars.timerResetVars;

    vars.FormatTime = (Func<int, bool, string>)((time, file) => {
        return TimeSpan.FromMilliseconds(time).ToString(file ? @"mm\.ss\.fff" : @"mm\:ss\.fff");
    });

    vars.GetTrackNumber = (Func<string>)(() => {
        return vars.loadMap.Current.Substring(vars.loadMap.Current.Length-3, 2);
    });

    vars.GetCleanMapName = (Func<string>)(() => {
        return System.Text.RegularExpressions.Regex.Replace(vars.loadMap.Current.Substring(0, vars.loadMap.Current.Length-1), @"(\$[0-9a-fA-F]{3}|\$[wnoitsgzb]{1})", "");
    });

    vars.SetLogTimes = (Action<int, string>)((time, detail) => {
        vars.totalGameTime += time;
        int logNb = 1;
        string cleanName = vars.GetCleanMapName();
        while(true) {
            string timeEntry = cleanName + (logNb == 1 && String.IsNullOrEmpty(detail) ? "" : " ("+detail+logNb+")");
            if(!vars.logTimes.ContainsKey(timeEntry)) {
                vars.logTimes.Add(timeEntry, time);
                break;
            }
            ++logNb;
        }
    });
}

init {
    vars.timerLogTimes = (EventHandler)((s, e) => {
        if(timer.CurrentPhase == TimerPhase.Ended) {
            string separator = "  |  ";
            string category = timer.Run.CategoryName;
            foreach(KeyValuePair<string, string> kvp in timer.Run.Metadata.VariableValueNames)
                category += " - "+kvp.Value;
            string timesDisplay = string.Concat("Trackmania - ", category, Environment.NewLine, Environment.NewLine,
                                                "   Sum   ", separator, " Segment ", separator, "  Track", Environment.NewLine);
            int cumulatedTime = 0;
            foreach(KeyValuePair<string, int> kvp in vars.logTimes) {
                cumulatedTime += kvp.Value;
                timesDisplay += string.Concat(vars.FormatTime(cumulatedTime, false), separator, vars.FormatTime(kvp.Value, false), separator, kvp.Key, Environment.NewLine);
            }
            string chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
            long value = DateTimeOffset.Now.ToUnixTimeSeconds() / 30;
            string base36DateTime = "";
            while(value > 0) {
                base36DateTime = chars[(int)(value % 36)] + base36DateTime;
                value /= 36;
            }
            string path = string.Concat(Directory.GetCurrentDirectory(), "\\TrackmaniaTimes\\",
                                        category, "_", base36DateTime, "_", vars.FormatTime(cumulatedTime, true), ".log");
            string directoryName = Path.GetDirectoryName(path);
            if(!Directory.Exists(directoryName))
                Directory.CreateDirectory(directoryName);
            File.AppendAllText(path, timesDisplay);
        }
    });
    timer.OnSplit += vars.timerLogTimes;

    vars.tokenSource = new CancellationTokenSource();
    vars.token = vars.tokenSource.Token;

    vars.threadScan = new Thread(() => {
        var trackDataTarget = new SigScanTarget(0x0, "48 8B 83 ?? ?? ?? ?? C7 44 24 ?? ?? ?? ?? ?? 48 89");
        var gameTimeTarget = new SigScanTarget(0x10, "C3 CC CC CC CC CC CC CC CC CC 89 0D");
        var loadMapTarget = new SigScanTarget(0xC, "7F 23 45 33 C0");
        
        IntPtr trackDataPtr = IntPtr.Zero;
        IntPtr gameTimePtr = IntPtr.Zero;
        IntPtr loadMapPtr = IntPtr.Zero;

        var module = modules.First(m => m.ModuleName == "Trackmania.exe");

        while(!vars.token.IsCancellationRequested) {
            print("[Autosplitter] Scanning memory");
        
            var scanner = new SignatureScanner(game, module.BaseAddress, module.ModuleMemorySize);

            if((trackDataPtr = scanner.Scan(trackDataTarget)) != IntPtr.Zero)
                print("[Autosplitter] Track Data Found : " + trackDataPtr.ToString("X"));

            if((gameTimePtr = scanner.Scan(gameTimeTarget)) != IntPtr.Zero)
                print("[Autosplitter] GameTime Found : " + gameTimePtr.ToString("X"));

            if((loadMapPtr = scanner.Scan(loadMapTarget)) != IntPtr.Zero)
                print("[Autosplitter] Load Map Found : " + loadMapPtr.ToString("X"));

            if(trackDataPtr != IntPtr.Zero && gameTimePtr != IntPtr.Zero && loadMapPtr != IntPtr.Zero) {
                IntPtr trackData = trackDataPtr+game.ReadValue<int>(trackDataPtr-0x4);
                IntPtr gameTime = gameTimePtr+game.ReadValue<int>(gameTimePtr-0x4);
                IntPtr loadMap = loadMapPtr+game.ReadValue<int>(loadMapPtr-0x4);
                vars.watchers = new MemoryWatcherList() {
                    (vars.trackData = new MemoryWatcher<IntPtr>(new DeepPointer(trackData, 0xEC0))),
                    (vars.checkpoint = new MemoryWatcher<int>(new DeepPointer(trackData, 0xEC0, 0xD78, 0x660, 0x0, 0x678))),
                    (vars.inRace = new MemoryWatcher<bool>(new DeepPointer(trackData, 0xEC0, 0xD78, 0x660, 0x0, 0x6C0)) {FailAction = MemoryWatcher.ReadFailAction.SetZeroOrNull}),
                    (vars.raceTime = new MemoryWatcher<int>(new DeepPointer(trackData, 0xEC0, 0xD78, 0x8E8, 0xCD8, 0x140, 0x0, 0x32C0, 0x488, 0x4))),
                    (vars.isFinished = new MemoryWatcher<bool>(new DeepPointer(trackData, 0xEC0, 0xD78, 0x8E8, 0xCD8, 0x140, 0x0, 0x32C0, 0x488, 0x14))),
                    (vars.gameTime = new MemoryWatcher<int>(new DeepPointer(gameTime))),
                    (vars.loadMap = new StringWatcher(new DeepPointer(loadMap, 0x9), 64))
                };
                print("[Autosplitter] Done scanning");
                break;
            }
            Thread.Sleep(2000);
        }
        print("[Autosplitter] Exit thread scan");
    });
    vars.threadScan.Start();
}

update {
    if(vars.threadScan.IsAlive)
        return false;

    vars.watchers.UpdateAll(game);
}

start {
    return vars.gameTime.Old == 0 && vars.gameTime.Current > 0 && (vars.GetTrackNumber() == "01" || settings["cStart"]);
}

split {
    if(vars.trackData.Current == IntPtr.Zero || !vars.inRace.Current)
        return false;

    if(vars.raceTime.Changed && (vars.lastCP.Item1 != vars.loadMap.Current || vars.lastCP.Item2 < vars.checkpoint.Current)) {
        vars.lastCP = Tuple.Create(vars.loadMap.Current, vars.checkpoint.Current);
        if(vars.isFinished.Current) {
            if(settings["track"]) {
                return true;
            } else {
                string map = vars.loadMap.Current;
                if(settings["cTraining"] && map.StartsWith("Training"))
                    return settings["t"+vars.GetTrackNumber()];
                    
                if(settings["cSeason"] && (map.StartsWith("Winter") || map.StartsWith("Spring") || map.StartsWith("Summer") || map.StartsWith("Fall")))
                    return settings["s"+vars.GetTrackNumber()];
            }
        } else {
            return settings["checkpoint"];
        }
    }
}

reset {
    return vars.gameTime.Current == 0 && vars.startMap == vars.loadMap.Current;
}

isLoading {
    return true;
}

gameTime {
    if(vars.inRace.Current && !vars.inRace.Old) {
        vars.trackDone = false;
    } else if(vars.trackData.Current != IntPtr.Zero && vars.raceTime.Changed && vars.isFinished.Current) {
        vars.trackDone = true;
        vars.SetLogTimes(vars.raceTime.Current, "");
    }

    if(vars.inRace.Old && !vars.inRace.Current && !vars.trackDone) {
        vars.SetLogTimes(vars.gameTime.Old, "Reset ");
    }

    return TimeSpan.FromMilliseconds(vars.totalGameTime+(vars.inRace.Current && !vars.trackDone ? vars.gameTime.Current : 0));
}

exit {
    vars.tokenSource.Cancel();
    timer.OnSplit -= vars.timerLogTimes;
}

shutdown {
    vars.tokenSource.Cancel();
    timer.OnStart -= vars.timerResetVars;
    timer.OnSplit -= vars.timerLogTimes;
}
