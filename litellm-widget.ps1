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
    using System.Drawing;
    using System.Drawing.Drawing2D;
    using System.Globalization;
    using System.IO;
    using System.Linq;
    using System.Net.Http;
    using System.Net.Http.Headers;
    using System.Runtime.InteropServices;
    using System.Text;
    using System.Text.RegularExpressions;
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
        string baseUrl, apiKey, probeModel, cfgPath, posPath;
        int refreshSeconds = 60;
        const int OverLimitRefreshSeconds = 1800;  // over budget: 429s also count as failed calls, back off to 30 min
        double warnPct = 80.0, critPct = 95.0;
        double opacityVal = 0.85;
        string uiFontFamily = "Microsoft YaHei UI";

        // ---- ui ----
        Label lblTitle, lblStatus, lblMain, lblSub, lblPct;
        Panel barTrack, barFill;
        NotifyIcon tray;
        ContextMenuStrip menu;
        ToolTip toolTip;
        System.Windows.Forms.Timer uiTimer;

        // ---- state ----
        HttpClient http;
        double spend = -1, budget = -1;
        DateTime lastOk = DateTime.MinValue;
        bool busy = false, warnShown = false, critShown = false, overLimit = false, initDone = false;
        string errStatus = null;
        int failCount = 0;
        // multi-instance jitter: the proxy is an ELB-fronted cluster whose instances serve
        // stale spend values; display the MAX seen within a window so it never jumps backwards
        double[] spendHist = new double[10];
        DateTime[] spendHistAt = new DateTime[10];
        int spendHistIdx = 0;

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
            cfg.TryGetValue("api_key", out apiKey);
            string v;
            if (cfg.TryGetValue("refresh_seconds", out v)) { int n; if (int.TryParse(v, out n) && n >= 10) refreshSeconds = n; }
            if (cfg.TryGetValue("warn_pct", out v)) { double d; if (TryD(v, out d)) warnPct = d; }
            if (cfg.TryGetValue("crit_pct", out v)) { double d; if (TryD(v, out d)) critPct = d; }
            if (cfg.TryGetValue("opacity", out v)) { double d; if (TryD(v, out d) && d >= 0.30 && d <= 1.0) opacityVal = d; }
            if (cfg.TryGetValue("probe_model", out v) && v.Length > 0) probeModel = v; else probeModel = "Qwen3.8-Flash";
            // sanity: base_url must be a clean http(s) URL with no spaces (guards against corrupted config
            // where the whole file collapses into one line - otherwise it could swallow the api_key line)
            if (baseUrl != null && (baseUrl.IndexOf(' ') >= 0 || !baseUrl.StartsWith("http"))) baseUrl = null;
            if (apiKey != null && apiKey.Length == 0) apiKey = null;
        }
        static bool TryD(string s, out double d) { return double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out d); }

        void SaveConfig()
        {
            try
            {
                StringBuilder sb = new StringBuilder();
                sb.AppendLine("base_url=" + baseUrl);
                sb.AppendLine("api_key=" + apiKey);
                sb.AppendLine("refresh_seconds=" + refreshSeconds);
                sb.AppendLine("warn_pct=" + warnPct);
                sb.AppendLine("crit_pct=" + critPct);
                sb.AppendLine("opacity=" + opacityVal.ToString("0.##", CultureInfo.InvariantCulture));
                sb.AppendLine("probe_model=" + probeModel);
                File.WriteAllText(cfgPath, sb.ToString());
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
            Size = new Size(252, 106);
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

            Controls.Add(lblTitle);
            Controls.Add(lblStatus);
            Controls.Add(lblMain);
            Controls.Add(lblPct);
            Controls.Add(barTrack);
            Controls.Add(lblSub);

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
            if (budget <= 0 || spend < 0) return Color.FromArgb(120, 120, 128);
            double pct = spend / budget * 100.0;
            if (overLimit || pct >= critPct) return Color.FromArgb(244, 67, 54);
            if (pct >= warnPct) return Color.FromArgb(255, 152, 0);
            return Color.FromArgb(76, 175, 80);
        }

        // update fill width/color from current data (no custom Paint: renders via BackColor,
        // which works under occlusion / WM_PRINTCLIENT where Paint events do not fire)
        void PaintBar()
        {
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
            uiTimer.Interval = (overLimit ? OverLimitRefreshSeconds : Math.Max(10, refreshSeconds)) * 1000;
        }

        async void Poll()
        {
            if (busy) return;
            busy = true;
            try
            {
                errStatus = null;
                bool ok = await ProbeOnce();
                if (!ok)
                {
                    failCount++;
                    // repeated failure: probe model may be gone (403, no headers) - relearn
                    if (failCount == 2) await RelearnModel();
                }
                else failCount = 0;
            }
            catch (Exception ex) { errStatus = ex.Message; }
            finally
            {
                busy = false;
                Render();
                ApplyTimerInterval();
            }
        }

        async Task<bool> ProbeOnce()
        {
            HttpRequestMessage req = new HttpRequestMessage(HttpMethod.Post, baseUrl + "/chat/completions");
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
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
                    errStatus = "HTTP " + (int)resp.StatusCode + ": " + Trunc(body, 150);
                    return false;
                }
            }
            double newSpend, newBudget;
            if (!TryD(s, out newSpend) || !TryD(b, out newBudget)) { errStatus = "cannot parse: " + s + " / " + b; return false; }
            budget = newBudget;
            spend = MaxSpend(newSpend);   // jitter fix: cluster instances serve stale values
            lastOk = DateTime.Now;
            CheckThresholds();
            return true;
        }

        double MaxSpend(double fresh)
        {
            DateTime now = DateTime.Now;
            spendHist[spendHistIdx] = fresh;
            spendHistAt[spendHistIdx] = now;
            spendHistIdx = (spendHistIdx + 1) % spendHist.Length;
            // window: keep samples from the last 15 minutes; max of them is the best guess
            // at the real total. A genuine admin reset (all servers drop) ages out naturally.
            double max = -1;
            for (int i = 0; i < spendHist.Length; i++)
            {
                if ((now - spendHistAt[i]).TotalMinutes <= 15 && spendHist[i] > max) max = spendHist[i];
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

        async Task RelearnModel()
        {
            try
            {
                HttpRequestMessage req = new HttpRequestMessage(HttpMethod.Get, baseUrl + "/models");
                req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
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
                    await ProbeOnce();
                }
            }
            catch (Exception) { }
        }

        void CheckThresholds()
        {
            if (budget <= 0 || spend < 0) return;
            double pct = spend / budget * 100.0;
            string info = S("\\u5df2\\u7528\\u0020") + pct.ToString("0.#", CultureInfo.InvariantCulture) + S("\\u0025\\uff08\\u00a5") +
                          spend.ToString("0.##", CultureInfo.InvariantCulture) + S("\\u0020\\u002f\\u0020\\u00a5") +
                          budget.ToString("0.#", CultureInfo.InvariantCulture) + S("\\u0029");
            if (pct >= critPct && !critShown)
            {
                critShown = true; warnShown = true;
                tray.ShowBalloonTip(8000, S("\\u004c\\u0069\\u0074\\u0065\\u004c\\u004c\\u004d\\u0020\\u989d\\u5ea6\\u544a\\u6025"), info, ToolTipIcon.Warning);
            }
            else if (pct >= warnPct && !warnShown)
            {
                warnShown = true;
                tray.ShowBalloonTip(6000, S("\\u004c\\u0069\\u0074\\u0065\\u004c\\u004c\\u004d\\u0020\\u989d\\u5ea6\\u63d0\\u9192"), info, ToolTipIcon.Info);
            }
            if (pct < warnPct - 5) { warnShown = false; critShown = false; } // re-arm after admin reset
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
                if (spend >= 0 && budget > 0)
                {
                    double pct = spend / budget * 100.0;
                    overLimit = spend >= budget;
                    lblMain.Text = S("\\u00a5") + spend.ToString("0.##", CultureInfo.InvariantCulture) +
                                   S("\\u0020\\u002f\\u0020\\u00a5") + budget.ToString("0.##", CultureInfo.InvariantCulture);
                    lblPct.Text = (overLimit ? S("\\u2265") : "") + pct.ToString("0.#", CultureInfo.InvariantCulture) + "%";
                    Color c = LevelColor();
                    lblMain.ForeColor = (overLimit || pct >= warnPct) ? c : Color.White;
                    lblPct.ForeColor = c;
                    if (overLimit) { lblSub.Text = S("\\u5df2\\u8d85\\u9650\\uff0c\\u7b49\\u7ba1\\u7406\\u5458\\u91cd\\u7f6e"); lblSub.ForeColor = Color.FromArgb(244, 67, 54); }
                    else
                    {
                        lblSub.Text = S("\\u5269\\u4f59\\u0020\\u00a5") + (budget - spend).ToString("0.##", CultureInfo.InvariantCulture);
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
                // never dump raw baseUrl/apiKey: a corrupted config can merge the key into
                // other fields, and this file is a plain-text debug artifact
                string bstate = (baseUrl == null || baseUrl.IndexOf(' ') >= 0 || !baseUrl.StartsWith("http")) ? "INVALID" : "OK";
                string p = Path.Combine(Path.GetDirectoryName(cfgPath), "last-state.txt");
                File.WriteAllText(p, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") +
                    " | spend=" + spend.ToString(CultureInfo.InvariantCulture) +
                    " | budget=" + budget.ToString(CultureInfo.InvariantCulture) +
                    " | err=" + (errStatus == null ? "-" : AsciiOnly(errStatus)) +
                    " | failCount=" + failCount +
                    " | baseUrl=" + bstate +
                    " | keyLen=" + (apiKey == null ? -1 : apiKey.Length) +
                    " | model=" + probeModel +
                    " | opacity=" + Opacity.ToString("0.##", CultureInfo.InvariantCulture) +
                    " | dock=" + dockedEdge + (peeking ? "+peek" : ""));
            }
            catch (Exception) { }
        }

        void ExitApp()
        {
            SavePos();
            try { tray.Visible = false; tray.Dispose(); } catch (Exception) { }
            Application.Exit();
        }
    }
}
'@

Add-Type -TypeDefinition $source -ReferencedAssemblies @(
    'System.dll', 'System.Core.dll', 'System.Drawing.dll',
    'System.Windows.Forms.dll', 'System.Net.Http.dll'
)

[System.Windows.Forms.Application]::EnableVisualStyles()
$app = New-Object LiteLLMWidget.WidgetForm
[System.Windows.Forms.Application]::Run($app)
$mutex.ReleaseMutex() | Out-Null
