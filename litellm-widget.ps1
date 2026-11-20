# LiteLLM quota floating widget - single file, zero deps (PowerShell 5.1 + WinForms)
# Data source: x-litellm-key-spend / x-litellm-key-max-budget response headers
# Config file: %USERPROFILE%\.litellm-widget\config.ini
# KEEP THIS FILE ASCII-ONLY: PS 5.1 + Add-Type read BOM-less files as ANSI,
# any non-ASCII byte (even in comments) corrupts parsing / C# compilation.
$ErrorActionPreference = 'Stop'

# single instance guard
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'LiteLLMWidgetSingleInstance', [ref]$createdNew)
if (-not $createdNew) { Write-Output 'LiteLLM widget already running - exiting.'; Start-Sleep 2; exit 0 }

$source = @'
// ASCII only in this block: Add-Type writes a UTF-8 temp file but csc reads it as ANSI,
// so any non-ASCII char (incl. comments) corrupts line boundaries. UI text uses \u escapes.
namespace LiteLLMWidget
{
    using System;
    using System.Collections.Generic;
    using System.Diagnostics;
    using System.Drawing;
    using System.Drawing.Drawing2D;
    using System.Globalization;
    using System.IO;
    using System.Linq;
    using System.Management;
    using System.Net.Http;
    using System.Net.Http.Headers;
    using System.Net.Sockets;
    using System.Runtime.InteropServices;
    using System.Text;
    using System.Text.RegularExpressions;
    using System.Threading;
    using System.Threading.Tasks;
    using System.Windows.Forms;

    public class WidgetForm : Form
    {
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] static extern bool ReleaseCapture();
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);

        const int WM_NCLBUTTONDOWN = 0xA1;
        const int HT_CAPTION = 0x2;
        static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        const uint SWP_NOMOVE = 0x2, SWP_NOSIZE = 0x1, SWP_NOACTIVATE = 0x10;

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT { public int X, Y; }

        static string S(string u) { return Regex.Unescape(u); } // runtime \uXXXX -> real chars

        // ---- config ----
        string baseUrl, probeModel, cfgPath, posPath;
        List<string> apiKeys = new List<string>();
        List<string> keyNames = new List<string>();
        int refreshSeconds = 60;
        const int MaxKeyRows = 8;                  // per-key lines drawn in the body; extras fold into "+N more"
        const int OverLimitRefreshSeconds = 1800;  // over budget: 429s also count as failed calls, back off to 30 min
        double warnPct = 80.0, critPct = 95.0;
        double opacityVal = 0.85;
        string uiFontFamily = "Microsoft YaHei UI";

        // ---- relay tunnel ----
        // The proxy's LB pins clients by source IP to instances with separate spend ledgers;
        // this desktop's egress lands on a stale one. Optional: forward probes through an
        // ssh tunnel so egress happens from the relay host's IP. All values from config.ini.
        bool relayEnabled = false;
        string relaySshHost, relaySshUser, relayTarget, relayUrl;
        int relaySshPort = 22, relayLocalPort = 18080;
        Process tunnel;                    // our ssh child (null = not spawned by us)
        DateTime lastSpawnAt = DateTime.MinValue;
        const int SpawnThrottleSeconds = 30;

        // ---- ui ----
        Label lblTitle, lblStatus, lblMain, lblSub, lblPct;
        List<Label> keyRowLabels = new List<Label>();   // one mini status line per key
        Panel barTrack, barFill;
        NotifyIcon tray;
        ContextMenuStrip menu;
        ToolTip toolTip;
        System.Windows.Forms.Timer uiTimer;

        // ---- state ----
        HttpClient http;
        List<KeyState> keys = new List<KeyState>();
        DateTime lastOk = DateTime.MinValue;       // newest successful probe across all keys
        bool busy = false, initDone = false;
        bool totalCritShown = false;
        string errStatus = null;

        // per-key probe state. Multi-instance jitter fix lives here too: the proxy is an
        // ELB-fronted cluster whose instances serve stale spend values, so each key shows
        // the MAX seen within a 15-minute window and never jumps backwards.
        class KeyState
        {
            public string key, name;
            public double spend = -1, budget = -1;
            public double[] spendHist = new double[10];
            public DateTime[] spendHistAt = new DateTime[10];
            public int spendHistIdx = 0;
            public int failCount = 0;
            public bool overLimit = false, warnShown = false, critShown = false;
            public DateTime lastOk = DateTime.MinValue, lastProbeAt = DateTime.MinValue;
            public string err = null;
            // an over-limit key backs off to 30 min (429s count as failed calls at the
            // gateway and can get the key banned); healthy keys keep the normal cadence
            public bool Due(int normalSec, int overSec)
            {
                int interval = overLimit ? overSec : normalSec;
                return (DateTime.Now - lastProbeAt).TotalSeconds >= interval;
            }
        }

        bool AllOverLimit()
        {
            if (keys.Count == 0) return false;
            foreach (KeyState ks in keys) if (!ks.overLimit) return false;
            return true;
        }

        // aggregate across keys that have produced numbers at least once
        void Totals(out double spend, out double budget, out int okKeys, out int overKeys)
        {
            spend = 0; budget = 0; okKeys = 0; overKeys = 0;
            foreach (KeyState ks in keys)
                if (ks.spend >= 0 && ks.budget > 0)
                {
                    spend += ks.spend; budget += ks.budget; okKeys++;
                    if (ks.overLimit) overKeys++;
                }
        }

        // ---- edge dock / auto-hide ----
        enum Edge { None, Left, Right }
        Edge dockedEdge = Edge.None;
        bool peeking = false;
        System.Windows.Forms.Timer peekTimer;   // fast: watch cursor near docked edge
        System.Windows.Forms.Timer hideTimer;   // one-shot: retract after cursor leaves
        const int DockSnapPx = 12;              // drop within this of an edge => dock
        const int PeekTriggerPx = 8;            // cursor within this of screen edge => peek
        const int HideDelayMs = 500;            // retract delay after cursor leaves
        int homeX, homeY;                       // on-screen position while docked

        public WidgetForm()
        {
            SetProcessDPIAware();
            string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".litellm-widget");
            cfgPath = Path.Combine(dir, "config.ini");
            posPath = Path.Combine(dir, "pos.txt");
            LoadConfig();
            if (keys.Count == 0) errStatus = "no usable api_keys in config.ini";
            if (relayEnabled) KillOrphanTunnels();   // clear tunnels left by a crashed widget
            PickFont();
            BuildUi();
            BuildTray();
            InitHttp();
            uiTimer = new System.Windows.Forms.Timer();
            ApplyTimerInterval();
            uiTimer.Tick += delegate { if (!busy) Poll(); };

            peekTimer = new System.Windows.Forms.Timer();
            peekTimer.Interval = 150;
            peekTimer.Tick += delegate { PeekWatch(); };
            hideTimer = new System.Windows.Forms.Timer();
            hideTimer.Interval = HideDelayMs;
            hideTimer.Tick += delegate { hideTimer.Stop(); Retract(); };
            LoadPos();
            Shown += delegate
            {
                initDone = true;
                RestoreDockState();
                peekTimer.Start();
                Poll();
                uiTimer.Start();
            };
            tray.ShowBalloonTip(2000, S("\\u004c\\u0069\\u0074\\u0065\\u004c\\u004c\\u004d\\u0020\\u989d\\u5ea6\\u76d1\\u63a7"),
                S("\\u5df2\\u542f\\u52a8\\uff0c\\u6bcf\\u0020") + refreshSeconds +
                S("\\u0020\\u79d2\\u81ea\\u52a8\\u5237\\u65b0\\uff0c\\u8d85\\u9650\\u65f6\\u002030\\u0020\\u5206\\u949f\\u4e00\\u6b21"), ToolTipIcon.Info);
        }

        // =============== config ===============
        void LoadConfig()
        {
            Dictionary<string, string> cfg = new Dictionary<string, string>();
            try
            {
                foreach (string line in File.ReadAllLines(cfgPath))
                {
                    string l = line.Trim();
                    if (l.Length == 0 || l.StartsWith("#") || l.StartsWith(";")) continue;
                    int i = l.IndexOf('=');
                    if (i > 0) cfg[l.Substring(0, i).Trim().ToLowerInvariant()] = l.Substring(i + 1).Trim();
                }
            }
            catch (Exception) { }
            cfg.TryGetValue("base_url", out baseUrl);
            // multi-key: api_keys=k1,k2,... (comma separated); legacy single api_key still accepted
            string keysLine = null;
            cfg.TryGetValue("api_keys", out keysLine);
            if (keysLine != null)
                foreach (string k in keysLine.Split(','))
                {
                    string t = k.Trim();
                    if (t.Length > 0) apiKeys.Add(t);   // drop empties (guards against corrupted config)
                }
            if (apiKeys.Count == 0)
            {
                string legacy; cfg.TryGetValue("api_key", out legacy);
                if (legacy != null && legacy.Length > 0) apiKeys.Add(legacy);
            }
            string namesLine = null;
            cfg.TryGetValue("key_names", out namesLine);
            if (namesLine != null)
                foreach (string n in namesLine.Split(',')) { string t = n.Trim(); if (t.Length > 0) keyNames.Add(t); }
            string v;
            if (cfg.TryGetValue("refresh_seconds", out v)) { int n; if (int.TryParse(v, out n) && n >= 10) refreshSeconds = n; }
            if (cfg.TryGetValue("warn_pct", out v)) { double d; if (TryD(v, out d)) warnPct = d; }
            if (cfg.TryGetValue("crit_pct", out v)) { double d; if (TryD(v, out d)) critPct = d; }
            if (cfg.TryGetValue("opacity", out v)) { double d; if (TryD(v, out d) && d >= 0.30 && d <= 1.0) opacityVal = d; }
            if (cfg.TryGetValue("probe_model", out v) && v.Length > 0) probeModel = v; else probeModel = "Qwen3.8-Flash";
            // sanity: base_url must be a clean http(s) URL with no spaces (guards against corrupted config
            // where the whole file collapses into one line - otherwise it could swallow the api_keys line)
            if (baseUrl != null && (baseUrl.IndexOf(' ') >= 0 || !baseUrl.StartsWith("http"))) baseUrl = null;
            // relay: optional ssh tunnel so probes egress from the relay host's IP
            if (cfg.TryGetValue("relay_enabled", out v)) relayEnabled = (v == "1" || v == "true" || v == "True");
            cfg.TryGetValue("relay_ssh_host", out relaySshHost);
            cfg.TryGetValue("relay_ssh_user", out relaySshUser);
            if (cfg.TryGetValue("relay_ssh_port", out v)) { int n; if (int.TryParse(v, out n) && n > 0) relaySshPort = n; }
            if (cfg.TryGetValue("relay_local_port", out v)) { int n; if (int.TryParse(v, out n) && n > 0) relayLocalPort = n; }
            if (cfg.TryGetValue("relay_target", out v) && v.Length > 0) relayTarget = v;
            if (relayEnabled)
            {
                try
                {
                    if (relayTarget == null) { Uri u = new Uri(baseUrl); relayTarget = u.Host + ":" + u.Port; }
                    UriBuilder ub = new UriBuilder(new Uri(baseUrl));
                    ub.Host = "127.0.0.1"; ub.Port = relayLocalPort;
                    relayUrl = ub.Uri.ToString().TrimEnd('/');
                }
                catch (Exception) { relayEnabled = false; }
                if (relaySshHost == null || relaySshUser == null || relayTarget == null) relayEnabled = false;
            }
            // materialize per-key state; names default to k1,k2,... (state file uses indexes,
            // names may be non-ASCII - only the UI renders them)
            keys.Clear();
            for (int i = 0; i < apiKeys.Count; i++)
                keys.Add(new KeyState { key = apiKeys[i], name = (i < keyNames.Count ? keyNames[i] : "k" + (i + 1)) });
        }
        static bool TryD(string s, out double d) { return double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out d); }

        void SaveConfig()
        {
            try
            {
                // write-through of ONLY the two fields the widget itself changes
                // (wheel opacity, model relearn). The whole-file rewrite we used
                // before silently reverted hand edits to api_keys/key_names made
                // while the widget was running. Unknown/comment lines are kept.
                List<string> lines = new List<string>();
                try { foreach (string l in File.ReadAllLines(cfgPath)) lines.Add(l); }
                catch (Exception) { }
                bool opDone = false, modelDone = false;
                for (int i = 0; i < lines.Count; i++)
                {
                    string t = lines[i].TrimStart();
                    if (t.StartsWith("#") || t.StartsWith(";")) continue;
                    if (t.StartsWith("opacity"))
                    {
                        lines[i] = "opacity=" + opacityVal.ToString("0.##", CultureInfo.InvariantCulture);
                        opDone = true;
                    }
                    else if (t.StartsWith("probe_model"))
                    {
                        lines[i] = "probe_model=" + probeModel;
                        modelDone = true;
                    }
                }
                if (!opDone) lines.Add("opacity=" + opacityVal.ToString("0.##", CultureInfo.InvariantCulture));
                if (!modelDone) lines.Add("probe_model=" + probeModel);
                File.WriteAllLines(cfgPath, lines.ToArray());
            }
            catch (Exception) { }
        }

        void PickFont()
        {
            try { if (!FontFamily.Families.Any(f => f.Name == uiFontFamily)) uiFontFamily = "Microsoft YaHei"; }
            catch (Exception) { uiFontFamily = "Segoe UI"; }
        }

        // =============== ui ===============
        void BuildUi()
        {
            FormBorderStyle = FormBorderStyle.None;
            TopMost = true;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            // base layout occupies the top 96px; one 17px mini line per key below it
            int rows = Math.Min(keys.Count, MaxKeyRows);
            Size = new Size(252, rows > 0 ? 96 + 17 * rows + 8 : 106);
            BackColor = Color.FromArgb(30, 30, 34);
            Font = new Font(uiFontFamily, 9F);
            Opacity = opacityVal;

            lblTitle = new Label();
            lblTitle.Text = S("\\u004c\\u0069\\u0074\\u0065\\u004c\\u004c\\u004d\\u0020\\u989d\\u5ea6");
            lblTitle.ForeColor = Color.FromArgb(150, 150, 158);
            lblTitle.Location = new Point(14, 10);
            lblTitle.AutoSize = true;

            lblStatus = new Label();
            lblStatus.Text = S("\\u2026");
            lblStatus.ForeColor = Color.FromArgb(120, 120, 128);
            lblStatus.Font = new Font(uiFontFamily, 8F);
            lblStatus.Location = new Point(Width - 88, 11);
            lblStatus.Size = new Size(74, 16);
            lblStatus.TextAlign = ContentAlignment.MiddleRight;

            lblMain = new Label();
            lblMain.Text = S("\\u2026");
            lblMain.ForeColor = Color.White;
            lblMain.Font = new Font(uiFontFamily, 14.25F, FontStyle.Bold);
            lblMain.Location = new Point(12, 30);
            lblMain.AutoSize = true;

            lblPct = new Label();
            lblPct.Text = "";
            lblPct.ForeColor = Color.FromArgb(150, 150, 158);
            lblPct.Font = new Font(uiFontFamily, 9F, FontStyle.Bold);
            lblPct.Location = new Point(Width - 60, 60);
            lblPct.Size = new Size(46, 18);
            lblPct.TextAlign = ContentAlignment.MiddleRight;

            barTrack = new Panel();
            barTrack.Location = new Point(14, 62);
            barTrack.Size = new Size(186, 10);
            barTrack.BackColor = Color.FromArgb(58, 58, 64);
            using (GraphicsPath tp = RoundPath(new Rectangle(0, 0, barTrack.Width - 1, barTrack.Height - 1), 5))
                barTrack.Region = new Region(tp);

            barFill = new Panel();
            barFill.Location = new Point(2, 2);
            barFill.Size = new Size(0, 6);
            barFill.BackColor = Color.FromArgb(76, 175, 80);
            barTrack.Controls.Add(barFill);

            lblSub = new Label();
            lblSub.Text = S("\\u7b49\\u5f85\\u6570\\u636e\\u2026");
            lblSub.ForeColor = Color.FromArgb(150, 150, 158);
            lblSub.Location = new Point(14, 78);
            lblSub.AutoSize = true;

            // per-key mini status lines under the aggregate block (Render fills the text;
            // when keys exceed MaxKeyRows the last line becomes "+N more")
            int rowY = 96;
            for (int i = 0; i < rows; i++)
            {
                Label lr = new Label();
                lr.Text = S("\\u2026");
                lr.ForeColor = Color.FromArgb(150, 150, 158);
                lr.Font = new Font(uiFontFamily, 8F);
                lr.Location = new Point(14, rowY);
                lr.Size = new Size(224, 15);
                keyRowLabels.Add(lr);
                rowY += 17;
            }

            Controls.Add(lblTitle);
            Controls.Add(lblStatus);
            Controls.Add(lblMain);
            Controls.Add(lblPct);
            Controls.Add(barTrack);
            Controls.Add(lblSub);
            foreach (Label lr in keyRowLabels) Controls.Add(lr);

            toolTip = new ToolTip();

            menu = new ContextMenuStrip();
            ToolStripMenuItem miRefresh = new ToolStripMenuItem(S("\\u7acb\\u5373\\u5237\\u65b0"));
            miRefresh.Click += delegate { RefreshNow(); };
            ToolStripMenuItem miExit = new ToolStripMenuItem(S("\\u9000\\u51fa"));
            miExit.Click += delegate { ExitApp(); };
            menu.Items.Add(miRefresh);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(miExit);
            ContextMenuStrip = menu;

            EnableDrag(this);

            SizeChanged += delegate { UpdateRegion(); };
            UpdateRegion();

            LocationChanged += delegate { if (initDone) SavePos(); };
        }

        void BuildTray()
        {
            tray = new NotifyIcon();
            tray.Visible = true;
            tray.Text = S("\\u004c\\u0069\\u0074\\u0065\\u004c\\u004c\\u004d\\u0020\\u989d\\u5ea6");
            tray.ContextMenuStrip = menu;
            tray.DoubleClick += delegate { RefreshNow(); };
            using (Bitmap bm = new Bitmap(16, 16))
            {
                using (Graphics g = Graphics.FromImage(bm))
                {
                    g.Clear(Color.Transparent);
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    using (SolidBrush b = new SolidBrush(Color.FromArgb(66, 165, 245))) g.FillEllipse(b, 0, 0, 15, 15);
                    using (SolidBrush b = new SolidBrush(Color.White)) g.DrawString(S("\\u00a5"), new Font("Segoe UI", 9F, FontStyle.Bold), b, 2, 0);
                }
                tray.Icon = Icon.FromHandle(bm.GetHicon());
            }
        }

        void EnableDrag(Control c)
        {
            c.MouseDown += delegate(object s, MouseEventArgs e) { if (e.Button == MouseButtons.Left) DragStart(); };
            c.DoubleClick += delegate { RefreshNow(); };
            c.MouseWheel += new MouseEventHandler(OnWidgetWheel);
            c.ContextMenuStrip = menu;
            foreach (Control ch in c.Controls) EnableDrag(ch);
        }
        void OnWidgetWheel(object s, MouseEventArgs e)
        {
            // live opacity adjust: wheel up = more opaque, clamped 0.30..1.00, persisted
            double nv = opacityVal + (e.Delta > 0 ? 0.05 : -0.05);
            if (nv < 0.30) nv = 0.30;
            if (nv > 1.0) nv = 1.0;
            if (nv != opacityVal)
            {
                opacityVal = nv;
                Opacity = opacityVal;
                SaveConfig();
            }
        }
        void DragStart()
        {
            // dragging always un-hides first so the user grabs the real window
            if (dockedEdge != Edge.None && !peeking) PeekNow(true);
            ReleaseCapture();
            SendMessage(Handle, WM_NCLBUTTONDOWN, (IntPtr)HT_CAPTION, IntPtr.Zero);
        }

        // =============== edge dock / auto-hide ===============
        Rectangle WorkArea() { return Screen.GetWorkingArea(this); }

        void OnMoveEnd()
        {
            if (initDone) SavePos();
            Rectangle wa = WorkArea();
            bool nearL = Location.X <= wa.Left + DockSnapPx;
            bool nearR = Location.X + Width >= wa.Right - DockSnapPx;
            if (nearL || nearR)
            {
                dockedEdge = nearR ? Edge.Right : Edge.Left;
                // clamp fully onto the work area, vertical position preserved
                homeX = dockedEdge == Edge.Right ? wa.Right - Width : wa.Left;
                homeY = Math.Min(Math.Max(Location.Y, wa.Top), wa.Bottom - Height);
                Location = new Point(homeX, homeY);
                if (initDone) SavePos();
                Retract();      // dock immediately hides
            }
            else if (dockedEdge != Edge.None)
            {
                dockedEdge = Edge.None;   // dragged away from edge: normal mode
                peeking = false;
                peekTimer.Stop();
                hideTimer.Stop();
                Opacity = opacityVal;
            }
        }

        void PeekWatch()
        {
            if (dockedEdge == Edge.None) { peekTimer.Stop(); return; }
            POINT p;
            if (!GetCursorPos(out p)) return;
            Rectangle wa = WorkArea();
            bool atEdge = dockedEdge == Edge.Right
                ? p.X >= wa.Right - PeekTriggerPx
                : p.X <= wa.Left + PeekTriggerPx;
            // hover zone around the visible part of the window (the 6px strip counts)
            Rectangle hover = new Rectangle(Location.X - 20, Location.Y - 20, Width + 40, Height + 40);
            bool overUs = hover.Contains(p.X, p.Y);
            // approach detection: moving fast toward the docked edge inside the outer band.
            // People rarely park EXACTLY at the edge; a quick sweep that ends near it is intent.
            int distFromEdge = dockedEdge == Edge.Right ? (wa.Right - p.X) : (p.X - wa.Left);
            bool approaching = false;
            if (distFromEdge >= 0 && distFromEdge < 40)
            {
                int dx = p.X - lastCursorX;
                if ((dockedEdge == Edge.Right && dx > 18) || (dockedEdge == Edge.Left && dx < -18))
                    approaching = true;   // fast move (18px/150ms) toward the edge
            }
            lastCursorX = p.X;
            if ((atEdge || overUs || approaching) && !peeking) PeekNow(false);
            else if (!(atEdge || overUs) && peeking)
            {
                // during the outbound slide the window is still traveling toward the user;
                // only start the hide countdown once it has landed (or on a retract slide)
                if (!SlideBusy || !slideOutbound) ArmHide();
            }
        }
        int lastCursorX = -1;

        void PeekNow(bool instant)
        {
            peeking = true;
            hideTimer.Stop();
            if (instant)
            {
                Location = new Point(homeX, homeY);
                Opacity = opacityVal;
            }
            else
            {
                SlideTo(new Point(homeX, homeY), true);
            }
        }

        void Retract()
        {
            peeking = false;
            Rectangle wa = WorkArea();
            // slide out leaving a thin grab strip visible along the edge
            int hiddenX = dockedEdge == Edge.Right ? wa.Right - 6 : wa.Left - Width + 6;
            SlideTo(new Point(hiddenX, homeY), false);
        }

        void ArmHide()
        {
            if (!hideTimer.Enabled) hideTimer.Start();
        }

        // ---- non-blocking slide: animation timer moves the window a few px per tick ----
        Point slideFrom, slideToTarget;
        int slideStep, slideSteps = 6;
        bool slideOutbound;   // true = sliding OUT (peek), false = sliding back (retract)
        System.Windows.Forms.Timer slideTimer;
        void SlideTo(Point target, bool outbound)
        {
            slideFrom = Location;
            slideToTarget = target;
            slideStep = 0;
            slideOutbound = outbound;
            if (slideTimer == null)
            {
                slideTimer = new System.Windows.Forms.Timer();
                slideTimer.Interval = 20;
                slideTimer.Tick += delegate
                {
                    slideStep++;
                    if (slideStep >= slideSteps)
                    {
                        slideTimer.Stop();
                        Location = slideToTarget;
                        // after an outbound slide lands, re-evaluate the cursor: if the user
                        // already moved away mid-animation, arm the hide right now
                        if (slideOutbound) PeekWatch();
                        return;
                    }
                    int x = slideFrom.X + (slideToTarget.X - slideFrom.X) * slideStep / slideSteps;
                    int y = slideFrom.Y + (slideToTarget.Y - slideFrom.Y) * slideStep / slideSteps;
                    SetWindowPos(Handle, IntPtr.Zero, x, y, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE);
                };
            }
            slideTimer.Stop();
            slideTimer.Start();
        }
        bool SlideBusy { get { return slideTimer != null && slideTimer.Enabled; } }

        protected override bool ShowWithoutActivation { get { return true; } }
        protected override void WndProc(ref Message m)
        {
            const int WM_EXITSIZEMOVE = 0x232;
            if (m.Msg == WM_EXITSIZEMOVE) OnMoveEnd();
            base.WndProc(ref m);
        }
        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x80; // WS_EX_TOOLWINDOW: keep out of Alt+Tab
                return cp;
            }
        }

        GraphicsPath RoundPath(Rectangle r, int rad)
        {
            int d = rad * 2;
            GraphicsPath p = new GraphicsPath();
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }
        void UpdateRegion()
        {
            try
            {
                using (GraphicsPath p = RoundPath(new Rectangle(0, 0, Width - 1, Height - 1), 14))
                {
                    Region = new Region(p);
                    Invalidate();
                }
            }
            catch (Exception) { }
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath p = RoundPath(new Rectangle(0, 0, Width - 1, Height - 1), 14))
            using (Pen pen = new Pen(Color.FromArgb(72, 72, 80), 1.2f)) e.Graphics.DrawPath(pen, p);
        }

        Color LevelColor()
        {
            double spend, budget; int okKeys, overKeys;
            Totals(out spend, out budget, out okKeys, out overKeys);
            if (budget <= 0 || spend < 0) return Color.FromArgb(120, 120, 128);
            double pct = spend / budget * 100.0;
            if ((okKeys > 0 && overKeys == okKeys) || pct >= critPct) return Color.FromArgb(244, 67, 54);
            if (pct >= warnPct) return Color.FromArgb(255, 152, 0);
            return Color.FromArgb(76, 175, 80);
        }

        Color KeyLevelColor(KeyState ks)
        {
            if (ks.budget <= 0 || ks.spend < 0) return Color.FromArgb(120, 120, 128);
            double pct = ks.spend / ks.budget * 100.0;
            if (ks.overLimit || pct >= critPct) return Color.FromArgb(244, 67, 54);
            if (pct >= warnPct) return Color.FromArgb(255, 152, 0);
            return Color.FromArgb(76, 175, 80);
        }

        // update fill width/color from current data (no custom Paint: renders via BackColor,
        // which works under occlusion / WM_PRINTCLIENT where Paint events do not fire)
        void PaintBar()
        {
            double spend, budget; int okKeys, overKeys;
            Totals(out spend, out budget, out okKeys, out overKeys);
            double p = (budget > 0 && spend >= 0) ? Math.Min(spend / budget, 1.0) : 0.0;
            int w = (int)Math.Round((barTrack.Width - 4) * p);
            if (w < 2) w = 0; else if (w > barTrack.Width - 4) w = barTrack.Width - 4;
            if (barFill.Width != w)
            {
                barFill.Width = w;
                if (w > 0)
                {
                    using (GraphicsPath fp = RoundPath(new Rectangle(0, 0, w - 1, barFill.Height - 1), 3))
                        barFill.Region = new Region(fp);
                }
            }
            barFill.BackColor = LevelColor();
            barFill.Visible = w > 0;
        }

        // =============== position ===============
        void LoadPos()
        {
            Rectangle wa = Screen.PrimaryScreen.WorkingArea;
            Location = new Point(wa.Right - Width - 12, wa.Top + 12);
            try
            {
                if (File.Exists(posPath))
                {
                    string[] parts = File.ReadAllText(posPath).Split(',');
                    int x = int.Parse(parts[0].Trim()), y = int.Parse(parts[1].Trim());
                    Rectangle vs = SystemInformation.VirtualScreen;
                    if (x >= vs.Left - Width + 80 && x <= vs.Right - 80 && y >= vs.Top && y <= vs.Bottom - 60)
                        Location = new Point(x, y);
                }
            }
            catch (Exception) { }
        }
        void SavePos()
        {
            // while docked+hidden, persist the on-screen home position, not the retracted one
            int x = Location.X, y = Location.Y;
            if (dockedEdge != Edge.None && !peeking) { x = homeX; y = homeY; }
            try { File.WriteAllText(posPath, x + "," + y); } catch (Exception) { }
        }

        void RestoreDockState()
        {
            // if the saved position sits at a work-area edge, re-dock (and hide) there
            Rectangle wa = WorkArea();
            if (Location.X <= wa.Left + DockSnapPx || Location.X + Width >= wa.Right - DockSnapPx)
            {
                OnMoveEnd();     // routes through dock logic
            }
        }

        // =============== relay tunnel ===============
        string TunnelSpec { get { return "127.0.0.1:" + relayLocalPort + ":" + relayTarget; } }

        bool PortListening()
        {
            try
            {
                using (TcpClient c = new TcpClient())
                {
                    IAsyncResult ar = c.BeginConnect("127.0.0.1", relayLocalPort, null, null);
                    if (!ar.AsyncWaitHandle.WaitOne(400)) return false;
                    try { c.EndConnect(ar); return true; } catch (Exception) { return false; }
                }
            }
            catch (Exception) { return false; }
        }

        void KillOrphanTunnels()
        {
            // kill any ssh holding OUR forward spec (spec is built from config at runtime,
            // so nothing environment-specific lives in the source); a crashed widget can
            // leave one behind holding the local port
            try
            {
                string spec = "-L " + TunnelSpec;
                foreach (ManagementObject mo in new ManagementObjectSearcher(
                    "SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name = 'ssh.exe'").Get())
                {
                    string cl = Convert.ToString(mo["CommandLine"]);
                    if (cl != null && cl.IndexOf(spec, StringComparison.Ordinal) >= 0)
                    {
                        try { Process.GetProcessById(Convert.ToInt32(mo["ProcessId"])).Kill(); }
                        catch (Exception) { }
                    }
                }
            }
            catch (Exception) { }
            for (int i = 0; i < 15 && PortListening(); i++) Thread.Sleep(200);
        }

        bool EnsureTunnel()
        {
            if (PortListening()) return true;   // healthy - ours or reused from a previous run
            if (tunnel != null)
            {
                try { if (!tunnel.HasExited) tunnel.Kill(); } catch (Exception) { }
                tunnel = null;
            }
            if ((DateTime.Now - lastSpawnAt).TotalSeconds < SpawnThrottleSeconds) return false;
            lastSpawnAt = DateTime.Now;
            string args = "-N -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15" +
                          " -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3" +
                          " -p " + relaySshPort + " -L " + TunnelSpec + " " + relaySshUser + "@" + relaySshHost;
            try { tunnel = StartHidden("ssh", args); }
            catch (Exception) { try { tunnel = StartHidden(@"C:\Windows\System32\OpenSSH\ssh.exe", args); } catch (Exception) { return false; } }
            for (int i = 0; i < 20 && !tunnel.HasExited && !PortListening(); i++) Thread.Sleep(300);
            return PortListening();
        }

        static Process StartHidden(string exe, string arguments)
        {
            ProcessStartInfo pi = new ProcessStartInfo();
            pi.FileName = exe;
            pi.Arguments = arguments;
            pi.UseShellExecute = false;
            pi.CreateNoWindow = true;
            return Process.Start(pi);
        }

        string ProbeBase()
        {
            if (relayEnabled && PortListening()) return relayUrl;
            return baseUrl;
        }

        // =============== polling ===============
        void InitHttp()
        {
            HttpClientHandler h = new HttpClientHandler();
            h.UseProxy = false; // system proxy 127.0.0.1:12000 cannot reach the endpoint - bypass it
            http = new HttpClient(h);
            http.Timeout = TimeSpan.FromSeconds(15);
        }

        void RefreshNow() { if (!busy) Poll(); }

        void ApplyTimerInterval()
        {
            uiTimer.Interval = (AllOverLimit() ? OverLimitRefreshSeconds : Math.Max(10, refreshSeconds)) * 1000;
        }

        async void Poll()
        {
            if (busy) return;
            busy = true;
            try
            {
                errStatus = null;
                DateTime now = DateTime.Now;
                bool anyTried = false, anyOk = false;
                // probe ONE key per cycle, the oldest due one: probes set ConnectionClose
                // (LB instance re-roll) and back-to-back requests to the same host hit the
                // socket-teardown race on .NET Framework. Spreading keys across cycles
                // removes the race entirely; each key refreshes every refreshSeconds*N
                // (still far below the 30-min over-limit backoff).
                KeyState pick = null;
                foreach (KeyState ks in keys)
                {
                    if (!ks.Due(Math.Max(10, refreshSeconds), OverLimitRefreshSeconds)) continue;
                    if (pick == null || ks.lastProbeAt < pick.lastProbeAt) pick = ks;
                }
                if (pick != null)
                {
                    anyTried = true;
                    pick.lastProbeAt = now;
                    bool ok = false;
                    try { ok = await ProbeOnce(pick); }
                    catch (Exception ex) { pick.err = ex.GetType().Name + ": " + ex.Message; }
                    if (ok) { anyOk = true; pick.err = null; pick.failCount = 0; }
                    else
                    {
                        pick.failCount++;
                        // repeated failure: probe model may be gone (403, no headers) - relearn
                        if (pick.failCount == 2) await RelearnModel(pick);
                    }
                }
                if (anyTried && !anyOk) errStatus = LastKeyErr();
            }
            catch (Exception ex) { errStatus = ex.GetType().Name + ": " + ex.Message; }
            finally
            {
                busy = false;
                Render();
                ApplyTimerInterval();
            }
        }

        string LastKeyErr()
        {
            foreach (KeyState ks in keys) if (ks.err != null) return ks.err;
            return "probe failed";
        }

        async Task<bool> ProbeOnce(KeyState ks)
        {
            string probeBase = baseUrl;
            if (relayEnabled)
            {
                bool tun = await Task.Run((Func<bool>)EnsureTunnel);
                if (tun) probeBase = relayUrl;
                else errStatus = "relay tunnel down - probing direct";
            }
            HttpRequestMessage req = new HttpRequestMessage(HttpMethod.Post, probeBase + "/chat/completions");
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", ks.key);
            // probe must SUCCEED: the gateway bans keys whose call failure rate exceeds
            // 80%. The old empty-messages guaranteed-400 probe is retired (it made every
            // poll a failed call); a valid 1-token "hi" costs ~2e-5 on a flash model.
            string json = "{\"model\":\"" + probeModel + "\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}";
            ByteArrayContent content = new ByteArrayContent(Encoding.UTF8.GetBytes(json));
            content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
            req.Content = content;
            // critical: close the connection after every poll. The proxy is an ELB-backed
            // cluster with per-instance (stale) spend ledgers; a pooled connection pins us
            // to ONE instance for the whole process lifetime and can park on a stale one.
            // A fresh connection per poll re-rolls the instance; the rolling-max then
            // converges to the freshest ledger.
            req.Headers.ConnectionClose = true;

            HttpResponseMessage resp = await http.SendAsync(req);
            string s = HeaderVal(resp, "x-litellm-key-spend");
            string b = HeaderVal(resp, "x-litellm-key-max-budget");
            if (s == null || b == null)
            {
                // over-budget case: 429 body carries "Current cost: X, Max budget: Y"
                string body = await resp.Content.ReadAsStringAsync();
                Match ms = Regex.Match(body, "Current cost: ([0-9.]+)");
                Match mb = Regex.Match(body, "Max budget: ([0-9.]+)");
                if (ms.Success && mb.Success) { s = ms.Groups[1].Value; b = mb.Groups[1].Value; }
                else
                {
                    ks.err = "HTTP " + (int)resp.StatusCode + ": " + Trunc(body, 150);
                    return false;
                }
            }
            double newSpend, newBudget;
            if (!TryD(s, out newSpend) || !TryD(b, out newBudget)) { ks.err = "cannot parse: " + s + " / " + b; return false; }
            ks.budget = newBudget;
            ks.spend = MaxSpend(ks, newSpend);   // jitter fix: cluster instances serve stale values
            ks.overLimit = ks.spend >= ks.budget;
            ks.lastOk = DateTime.Now;
            if (ks.lastOk > lastOk) lastOk = ks.lastOk;
            CheckThresholds(ks);
            return true;
        }

        double MaxSpend(KeyState ks, double fresh)
        {
            DateTime now = DateTime.Now;
            ks.spendHist[ks.spendHistIdx] = fresh;
            ks.spendHistAt[ks.spendHistIdx] = now;
            ks.spendHistIdx = (ks.spendHistIdx + 1) % ks.spendHist.Length;
            // window: keep samples from the last 15 minutes; max of them is the best guess
            // at the real total. A genuine admin reset (all servers drop) ages out naturally.
            double max = -1;
            for (int i = 0; i < ks.spendHist.Length; i++)
            {
                if ((now - ks.spendHistAt[i]).TotalMinutes <= 15 && ks.spendHist[i] > max) max = ks.spendHist[i];
            }
            if (max < 0) max = fresh;
            return max;
        }

        static string HeaderVal(HttpResponseMessage resp, string name)
        {
            IEnumerable<string> vals;
            if (resp.Headers.TryGetValues(name, out vals))
            {
                string v = vals.FirstOrDefault();
                if (v != null) return v.Trim();
            }
            return null;
        }

        async Task RelearnModel(KeyState ks)
        {
            try
            {
                HttpRequestMessage req = new HttpRequestMessage(HttpMethod.Get, ProbeBase() + "/models");
                req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", keys.Count > 0 ? keys[0].key : "");
                HttpResponseMessage resp = await http.SendAsync(req);
                string body = await resp.Content.ReadAsStringAsync();
                List<string> ids = Regex.Matches(body, "\"id\"\\s*:\\s*\"([^\"]+)\"")
                    .Cast<Match>().Select(m => m.Groups[1].Value).ToList();
                string pick = null;
                string[] pref = new string[] { "Qwen3.8-Flash", "GLM-5.3-Flash", "DeepSeek-V4-Flash", "MiniMax-M3", "GLM-5.3", "Qwen" };
                foreach (string p in pref)
                {
                    pick = ids.FirstOrDefault(x => x.IndexOf(p, StringComparison.OrdinalIgnoreCase) >= 0);
                    if (pick != null) break;
                }
                if (pick == null) pick = ids.FirstOrDefault();
                if (pick != null)
                {
                    probeModel = pick;
                    SaveConfig();
                    if (await ProbeOnce(ks)) ks.failCount = 0;
                }
            }
            catch (Exception) { }
        }

        void CheckThresholds(KeyState ks)
        {
            if (ks.budget <= 0 || ks.spend < 0) return;
            double pct = ks.spend / ks.budget * 100.0;
            string info = ks.name + S("\\u0020\\u5df2\\u7528\\u0020") + pct.ToString("0.#", CultureInfo.InvariantCulture) + S("\\u0025\\uff08\\u00a5") +
                          ks.spend.ToString("0.##", CultureInfo.InvariantCulture) + S("\\u0020\\u002f\\u0020\\u00a5") +
                          ks.budget.ToString("0.#", CultureInfo.InvariantCulture) + S("\\uff09");
            if (pct >= critPct && !ks.critShown)
            {
                ks.critShown = true; ks.warnShown = true;
                tray.ShowBalloonTip(8000, S("\\u004c\\u0069\\u0074\\u0065\\u004c\\u004c\\u004d\\u0020\\u989d\\u5ea6\\u544a\\u6025"), info, ToolTipIcon.Warning);
            }
            else if (pct >= warnPct && !ks.warnShown)
            {
                ks.warnShown = true;
                tray.ShowBalloonTip(6000, S("\\u004c\\u0069\\u0074\\u0065\\u004c\\u004c\\u004d\\u0020\\u989d\\u5ea6\\u63d0\\u9192"), info, ToolTipIcon.Info);
            }
            if (pct < warnPct - 5) { ks.warnShown = false; ks.critShown = false; } // re-arm after admin reset
        }

        // one aggregate-level crit balloon on top of the per-key ones (warn stays per-key
        // to avoid noise; totals flip red only when the WHOLE pool is nearly drained)
        void CheckTotalThresholds(double totSpend, double totBudget)
        {
            if (totBudget <= 0 || totSpend < 0) return;
            double pct = totSpend / totBudget * 100.0;
            string info = S("\\u603b\\u8ba1\\u5df2\\u7528\\u0020") + pct.ToString("0.#", CultureInfo.InvariantCulture) + S("\\u0025\\uff08\\u00a5") +
                          totSpend.ToString("0.##", CultureInfo.InvariantCulture) + S("\\u0020\\u002f\\u0020\\u00a5") +
                          totBudget.ToString("0.#", CultureInfo.InvariantCulture) + S("\\uff09");
            if (pct >= critPct && !totalCritShown)
            {
                totalCritShown = true;
                tray.ShowBalloonTip(8000, S("\\u004c\\u0069\\u0074\\u0065\\u004c\\u004c\\u004d\\u0020\\u989d\\u5ea6\\u544a\\u6025"), info, ToolTipIcon.Warning);
            }
            if (pct < warnPct - 5) totalCritShown = false;
        }

        // =============== render ===============
        void Render()
        {
            try
            {
                // re-assert topmost band each refresh: other apps steal it over time
                // (no x/y => never fights the docked/retracted position)
                SetWindowPos(Handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
                DumpState();
                double spend, budget; int okKeys, overKeys;
                Totals(out spend, out budget, out okKeys, out overKeys);
                CheckTotalThresholds(spend, budget);
                if (spend >= 0 && budget > 0)
                {
                    double pct = spend / budget * 100.0;
                    bool allOver = (okKeys > 0 && overKeys == okKeys);
                    lblMain.Text = S("\\u00a5") + spend.ToString("0.##", CultureInfo.InvariantCulture) +
                                   S("\\u0020\\u002f\\u0020\\u00a5") + budget.ToString("0.##", CultureInfo.InvariantCulture);
                    lblPct.Text = (allOver ? S("\\u2265") : "") + pct.ToString("0.#", CultureInfo.InvariantCulture) + "%";
                    Color c = LevelColor();
                    lblMain.ForeColor = (allOver || pct >= warnPct) ? c : Color.White;
                    lblPct.ForeColor = c;
                    if (allOver) { lblSub.Text = S("\\u5df2\\u5168\\u90e8\\u8d85\\u9650\\uff0c\\u7b49\\u7ba1\\u7406\\u5458\\u91cd\\u7f6e"); lblSub.ForeColor = Color.FromArgb(244, 67, 54); }
                    else
                    {
                        double remaining = 0;
                        foreach (KeyState ks in keys)
                            if (ks.spend >= 0 && ks.budget > 0) remaining += Math.Max(0, ks.budget - ks.spend);
                        lblSub.Text = S("\\u5269\\u4f59\\u0020\\u00a5") + remaining.ToString("0.##", CultureInfo.InvariantCulture) +
                                      (overKeys > 0 ? S("\\uff08") + overKeys + "/" + okKeys + S("\\u0020\\u8d85\\u9650\\uff09") : "");
                        lblSub.ForeColor = Color.FromArgb(150, 150, 158);
                    }
                    lblStatus.Text = lastOk.ToString("HH:mm:ss");
                    lblStatus.ForeColor = errStatus != null ? Color.FromArgb(255, 152, 0) : Color.FromArgb(120, 120, 128);
                    tray.Text = S("\\u004c\\u0069\\u0074\\u0065\\u004c\\u004c\\u004d\\u0020\\u00a5") +
                                spend.ToString("0.##", CultureInfo.InvariantCulture) + "/" + budget.ToString("0.#", CultureInfo.InvariantCulture);
                }
                else
                {
                    lblStatus.Text = errStatus != null ? S("\\u5931\\u8d25") : S("\\u2026");
                    lblStatus.ForeColor = Color.FromArgb(255, 152, 0);
                    lblSub.Text = S("\\u7b49\\u5f85\\u6570\\u636e\\u2026");
                }
                // per-key mini rows (indexes, stable order; extras fold into the last line)
                for (int i = 0; i < keyRowLabels.Count; i++)
                {
                    Label lr = keyRowLabels[i];
                    if (i >= keys.Count) { lr.Text = ""; continue; }
                    if (keys.Count > MaxKeyRows && i == MaxKeyRows - 1)
                    {
                        lr.Text = "+ " + (keys.Count - MaxKeyRows + 1) + " more";
                        lr.ForeColor = Color.FromArgb(120, 120, 128);
                        continue;
                    }
                    KeyState ks = keys[i];
                    if (ks.spend >= 0 && ks.budget > 0)
                    {
                        double kp = ks.spend / ks.budget * 100.0;
                        lr.Text = (ks.overLimit ? S("\\u8d85\\u9650\\u0020") : "") + ks.name + "  " +
                                  kp.ToString("0.#", CultureInfo.InvariantCulture) + "%" +
                                  S("\\u0020\\u0020\\u00a5") + ks.spend.ToString("0.##", CultureInfo.InvariantCulture) +
                                  "/" + ks.budget.ToString("0.#", CultureInfo.InvariantCulture);
                        lr.ForeColor = KeyLevelColor(ks);
                    }
                    else
                    {
                        lr.Text = ks.name + "  " + S("\\u2026") + (ks.err != null ? " !" : "");
                        lr.ForeColor = Color.FromArgb(120, 120, 128);
                    }
                }
                if (errStatus != null) toolTip.SetToolTip(lblStatus, errStatus);
                else toolTip.SetToolTip(lblStatus, S("\\u6700\\u8fd1\\u4e00\\u6b21\\u6210\\u529f\\u66f4\\u65b0\\uff08\\u53cc\\u51fb\\u7acb\\u5373\\u5237\\u65b0\\uff09"));
                PaintBar();
            }
            catch (Exception) { }
        }

        static string Trunc(string s, int n)
        {
            if (s == null) return "";
            s = s.Replace("\r", " ").Replace("\n", " ");
            return s.Length <= n ? s : s.Substring(0, n) + S("\\u2026");
        }

        static string AsciiOnly(string s)
        {
            // exception messages are locale-localized (e.g. Chinese "task canceled");
            // keep the debug file ASCII-readable instead of mojibake
            if (s == null) return "";
            char[] cs = new char[s.Length];
            int n = 0;
            foreach (char c in s) if (c < 128) cs[n++] = c;
            return new string(cs, 0, n);
        }

        void DumpState()
        {
            try
            {
                // never dump raw baseUrl/apiKeys: a corrupted config can merge the key into
                // other fields, and this file is a plain-text debug artifact. Keys appear as
                // stable indexes (k0,k1,...) because key_names may be non-ASCII.
                string bstate = (baseUrl == null || baseUrl.IndexOf(' ') >= 0 || !baseUrl.StartsWith("http")) ? "INVALID" : "OK";
                double totSpend, totBudget; int okKeys, overKeys;
                Totals(out totSpend, out totBudget, out okKeys, out overKeys);
                StringBuilder ksB = new StringBuilder(), klB = new StringBuilder();
                int worstFail = 0;
                for (int i = 0; i < keys.Count; i++)
                {
                    KeyState ks = keys[i];
                    if (i > 0) { ksB.Append(','); klB.Append(','); }
                    ksB.Append("k" + i + ":" + ks.spend.ToString(CultureInfo.InvariantCulture) +
                               "/" + ks.budget.ToString(CultureInfo.InvariantCulture) +
                               (ks.overLimit ? "/over" : ""));
                    klB.Append("k" + i + ":" + (ks.key == null ? -1 : ks.key.Length));
                    if (ks.failCount > worstFail) worstFail = ks.failCount;
                }
                string p = Path.Combine(Path.GetDirectoryName(cfgPath), "last-state.txt");
                File.WriteAllText(p, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") +
                    " | keys=" + (ksB.Length > 0 ? ksB.ToString() : "-") +
                    " | total=" + totSpend.ToString(CultureInfo.InvariantCulture) + "/" + totBudget.ToString(CultureInfo.InvariantCulture) +
                    " | err=" + (errStatus == null ? "-" : AsciiOnly(errStatus)) +
                    " | failCount=" + worstFail +
                    " | baseUrl=" + bstate +
                    " | keyLen=" + (klB.Length > 0 ? klB.ToString() : "-") +
                    " | model=" + probeModel +
                    " | opacity=" + Opacity.ToString("0.##", CultureInfo.InvariantCulture) +
                    " | dock=" + dockedEdge + (peeking ? "+peek" : "") +
                    " | relay=" + (relayEnabled ? (PortListening() ? "on" : "down") : "off"));
            }
            catch (Exception) { }
        }

        void ExitApp()
        {
            SavePos();
            if (tunnel != null) { try { if (!tunnel.HasExited) tunnel.Kill(); } catch (Exception) { } }
            try { tray.Visible = false; tray.Dispose(); } catch (Exception) { }
            Application.Exit();
        }
    }
}
'@

Add-Type -TypeDefinition $source -ReferencedAssemblies @(
    'System.dll', 'System.Core.dll', 'System.Drawing.dll',
    'System.Windows.Forms.dll', 'System.Net.Http.dll', 'System.Management.dll'
)

[System.Windows.Forms.Application]::EnableVisualStyles()
$app = New-Object LiteLLMWidget.WidgetForm
[System.Windows.Forms.Application]::Run($app)
$mutex.ReleaseMutex() | Out-Null
