using System.Net.Http;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Cirrus.Core;

namespace Cirrus.App.UI;

/// <summary>
/// Apple ID sign-in: password (SRP — the password goes only to Apple), two-factor code (trusted device or
/// SMS), then Advanced Data Protection approval when the account needs it. Saved passwords are protected
/// with DPAPI and only released after Windows Hello or the Windows password.
/// </summary>
sealed class SignInWindow : Window
{
    readonly TextBox _apple = new() { Margin = new Thickness(0, 4, 0, 4) };
    readonly PasswordBox _pass = new() { Margin = new Thickness(0, 4, 0, 4) };
    readonly CheckBox _remember;
    readonly TextBox _code = new() { FontSize = 22, MaxLength = 6, HorizontalContentAlignment = HorizontalAlignment.Center, Width = 180, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 6) };
    readonly ComboBox _phones = new() { Visibility = Visibility.Collapsed, Margin = new Thickness(0, 4, 0, 4) };
    readonly Button _sms, _primary, _saved;
    readonly TextBlock _headline = Ui.Text("Sign in to iCloud", 18, bold: true);
    readonly TextBlock _blurb = Ui.Text("", 12, opacity: 0.75);
    readonly TextBlock _status = Ui.Text("", 12);
    readonly ProgressBar _spinner = new() { IsIndeterminate = true, Height = 3, Visibility = Visibility.Hidden, Margin = new Thickness(0, 8, 0, 0) };
    readonly StackPanel _creds = new(), _codeBox = new() { Visibility = Visibility.Collapsed };
    enum Step { Creds, Code, Approval }
    Step _step = Step.Creds;
    bool _busy;
    ICloudSession? _session;
    List<TrustedPhone> _phoneList = [];
    TrustedPhone? _smsPhone;

    public Account? SignedInAccount { get; private set; }

    public SignInWindow(string? appleID)
    {
        Title = "Sign In";
        Width = 480;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        _remember = Ui.Check("Remember password on this PC (encrypted with your Windows account; Windows Hello or your Windows password unlocks it when the session expires)", true);
        _sms = Ui.Button("Text Me a Code Instead", SendSms);
        _sms.Margin = new Thickness(0, 4, 0, 0);
        _sms.HorizontalAlignment = HorizontalAlignment.Left;
        _primary = Ui.Button("Sign In", Primary, accent: true, isDefault: true);
        _saved = Ui.Button("Sign In with Saved Password", UseSaved);
        _saved.Visibility = Visibility.Collapsed;
        var cancel = Ui.Button("Cancel", () => { DialogResult = false; }, isCancel: true);

        var head = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };
        var cloud = Ui.Glyph("\uE753", 34);
        cloud.Foreground = SystemColors.HighlightBrush;
        cloud.Margin = new Thickness(0, 0, 14, 0);
        head.Children.Add(cloud);
        head.Children.Add(_headline);
        _headline.VerticalAlignment = VerticalAlignment.Center;
        _blurb.Text = AccountManager.Shared.NativeAccount is not null
            ? "iCloud for Windows is set up on this PC, and Cirrus shows its folders automatically. Sign in here to browse iCloud Drive and Photos directly, or another Apple ID."
            : "Cirrus signs in the way iCloud.com does. Your password goes only to Apple, and two-factor authentication still applies.";

        _creds.Children.Add(Ui.Text("Apple ID (email or phone number)", 12, opacity: 0.85));
        _creds.Children.Add(_apple);
        _creds.Children.Add(Ui.Text("Password", 12, opacity: 0.85));
        _creds.Children.Add(_pass);
        _creds.Children.Add(_remember);

        _codeBox.Children.Add(_code);
        _codeBox.Children.Add(_phones);
        _codeBox.Children.Add(_sms);
        _code.TextChanged += (_, _) => { if (_step == Step.Code && Digits(_code.Text).Length == 6 && !_busy) SubmitCode(); };

        var root = Ui.Stack(head, _blurb, _creds, _codeBox, _spinner, _status, Ui.Buttons(_saved, _primary, cancel));
        root.Margin = new Thickness(24, 20, 24, 20);
        Content = root;

        _apple.Text = appleID ?? "";
        if (appleID is not null && AccountManager.Shared.Gate.HasSavedPassword(appleID)) _saved.Visibility = Visibility.Visible;
        Loaded += (_, _) => { if (appleID is null) _apple.Focus(); else _pass.Focus(); };
        Closed += (_, _) => { _pass.Clear(); if (SignedInAccount is null) _session?.Dispose(); };
    }

    static string Digits(string s) => new(s.Where(char.IsDigit).ToArray());

    void SetBusy(bool b, string msg = "")
    {
        _busy = b;
        _spinner.Visibility = b ? Visibility.Visible : Visibility.Hidden;
        _primary.IsEnabled = !b;
        _saved.IsEnabled = !b;
        _status.Foreground = (Brush)_blurb.Foreground ?? Brushes.Gray;
        _status.Text = msg;
    }

    void Fail(Exception e)
    {
        SetBusy(false);
        _status.Foreground = Brushes.IndianRed;
        _status.Text = e is AppleSRPClient.SRPException or ICloudException or TimeoutException or HttpRequestException ? e.Message : "Sign-in failed: " + e.Message;
        Log.Status("sign-in step failed: " + e.GetType().Name);
    }

    void Primary()
    {
        if (_busy) return;
        if (_step == Step.Creds) StartSignIn();
        else if (_step == Step.Code) SubmitCode();
        else DialogResult = SignedInAccount is not null;
    }

    async void UseSaved()
    {
        var id = _apple.Text.Trim().ToLowerInvariant();
        SetBusy(true, "Waiting for Windows Hello…");
        var pw = await AccountManager.Shared.Gate.PasswordAsync(id, "Sign in to iCloud with your saved Apple ID password");
        if (pw is null) { Fail(new Exception("Couldn’t unlock the saved password.")); return; }
        _pass.Password = pw;
        _busy = false;
        StartSignIn();
    }

    async void StartSignIn()
    {
        var appleID = _apple.Text.Trim().ToLowerInvariant();
        var pw = _pass.Password;
        if (appleID.Length == 0 || pw.Length == 0) { _status.Foreground = Brushes.IndianRed; _status.Text = "Enter your Apple ID and password."; return; }
        SetBusy(true, "Signing in…");
        _session?.Dispose();
        var s = AccountManager.Shared.PendingSession(appleID);
        _session = s;
        try
        {
            switch (await s.SignInAsync(pw))
            {
                case SignInOutcome.SignedIn: await Finish(); break;
                case SignInOutcome.NeedsCode nc: _phoneList = nc.Phones.ToList(); ShowCodeStep(nc.DeviceAvailable); break;
            }
        }
        catch (Exception e) { Fail(e); }
    }

    void ShowCodeStep(bool device)
    {
        SetBusy(false);
        _step = Step.Code;
        _creds.Visibility = Visibility.Collapsed;
        _codeBox.Visibility = Visibility.Visible;
        _saved.Visibility = Visibility.Collapsed;
        _headline.Text = "Two-Factor Authentication";
        _blurb.Text = device ? "Enter the verification code shown on your iPhone, iPad or Mac." : "Choose a phone number and Cirrus will text you a code.";
        _primary.Content = "Verify";
        _sms.Visibility = _phoneList.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (!device && _phoneList.Count > 0) SendSms();
        _code.Focus();
    }

    async void SendSms()
    {
        if (_session is null || _phoneList.Count == 0) return;
        if (_phoneList.Count > 1 && _phones.Visibility != Visibility.Visible)
        {
            _phones.ItemsSource = _phoneList.Select(p => p.Number).ToList();
            _phones.SelectedIndex = 0;
            _phones.Visibility = Visibility.Visible;
            _sms.Content = "Send Text Message";
            return;
        }
        var phone = _phoneList[_phoneList.Count > 1 ? Math.Max(0, _phones.SelectedIndex) : 0];
        _smsPhone = phone;
        SetBusy(true, $"Sending a code to {phone.Number}…");
        try { await _session.RequestSmsAsync(phone); SetBusy(false, $"Code sent to {phone.Number}."); _code.Focus(); }
        catch (Exception e) { Fail(e); }
    }

    async void SubmitCode()
    {
        var code = Digits(_code.Text);
        if (code.Length != 6 || _session is null) { _status.Foreground = Brushes.IndianRed; _status.Text = "Enter the 6-digit code."; return; }
        SetBusy(true, "Verifying…");
        try
        {
            if (_smsPhone is { } p) await _session.SubmitSmsCodeAsync(code, p); else await _session.SubmitCodeAsync(code);
            await Finish();
        }
        catch (Exception e) { Fail(e); _code.Text = ""; }
    }

    async Task Finish()
    {
        if (_session is null) return;
        var appleID = _session.AppleID;
        var remember = _remember.IsChecked == true ? _pass.Password : null;
        var acct = AccountManager.Shared.FinishSignIn(appleID, _session, remember);
        _session = null;
        _pass.Clear();
        SignedInAccount = acct;
        // Advanced Data Protection: get consent now so browsing doesn't stall later.
        var info = acct.Session!.AccountInfo;
        var needsPcs = info["webservices"]["drivews"]["pcsRequired"].Bool == true || info["webservices"]["ckdatabasews"]["pcsRequired"].Bool == true;
        if (needsPcs)
        {
            _step = Step.Approval;
            _codeBox.Visibility = Visibility.Collapsed;
            _creds.Visibility = Visibility.Collapsed;
            _headline.Text = "Approve Web Access";
            _blurb.Text = "This Apple ID uses Advanced Data Protection. Check your iPhone, iPad or Mac and approve the request to let Cirrus read your iCloud data.";
            _primary.Visibility = Visibility.Collapsed;
            SetBusy(true, "Waiting for approval…");
            try
            {
                await acct.Session.EnsurePcsAsync("iclouddrive", "drivews");
                await acct.Session.EnsurePcsAsync("photos", "ckdatabasews");
            }
            catch (Exception e)
            {
                Fail(e);
                _primary.Visibility = Visibility.Visible;
                _primary.Content = "Continue";
                return;
            }
        }
        SetBusy(false);
        DialogResult = true;
    }
}
