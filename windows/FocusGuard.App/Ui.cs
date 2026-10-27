using FocusGuard.Core;

namespace FocusGuard.App;

/// 화면 공통: 글꼴 · 색 · 자주 쓰는 컨트롤
static class Ui
{
    public static string L(string ko, string en) => I18n.L(ko, en);

    public static readonly Font Base = new("Segoe UI", 10f);
    public static readonly Font Small = new("Segoe UI", 8.5f);
    public static readonly Font Bold = new("Segoe UI", 10f, FontStyle.Bold);
    public static readonly Font Title = new("Segoe UI", 14f, FontStyle.Bold);
    public static readonly Font Big = new("Segoe UI", 20f, FontStyle.Bold);

    public static readonly Color Muted = Color.FromArgb(110, 110, 115);
    public static readonly Color Red = Color.FromArgb(214, 69, 69);
    public static readonly Color Green = Color.FromArgb(47, 158, 107);
    public static readonly Color Orange = Color.FromArgb(217, 130, 43);
    public static readonly Color Blue = Color.FromArgb(52, 120, 246);
    public static readonly Color CardBack = Color.FromArgb(244, 242, 240);

    public static Color KindColor(TodoKind k) => k switch { TodoKind.Must => Red, TodoKind.Nice => Blue, _ => Color.Gray };

    public static string KindTitle(TodoKind k) => k switch
    {
        TodoKind.Must => L("🔥 반드시 할 일", "🔥 Must do"),
        TodoKind.Nice => L("👍 하면 좋은 일", "👍 Nice to do"),
        _ => L("📎 기타 업무", "📎 Other"),
    };

    public static string KindPlaceholder(TodoKind k) => k switch
    {
        TodoKind.Must => L("꼭 끝낼 일 추가 (1~3개 추천)", "Add a must-do (1–3 is plenty)"),
        TodoKind.Nice => L("하면 좋은 일 추가", "Add a nice-to-do"),
        _ => L("기타 업무 추가", "Add another task"),
    };

    /// 글자. width 를 주면 그 너비에서 줄바꿈된다.
    public static Label Text(string text, Font? font = null, Color? color = null, int width = 0) => new()
    {
        Text = text,
        Font = font ?? Base,
        ForeColor = color ?? SystemColors.ControlText,
        AutoSize = true,
        MaximumSize = width > 0 ? new Size(width, 0) : Size.Empty,
        Margin = new Padding(0, 2, 0, 2),
        UseMnemonic = false,
    };

    public static Button Button(string text, Action onClick, bool primary = false, int width = 0)
    {
        var b = new Button
        {
            Text = text,
            Font = primary ? Bold : Base,
            AutoSize = width == 0,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Padding = new Padding(10, 4, 10, 4),
            Margin = new Padding(0, 2, 6, 2),
            UseMnemonic = false,
            UseVisualStyleBackColor = !primary,
        };
        if (width > 0) b.Size = new Size(width, 34);
        if (primary) { b.BackColor = Red; b.ForeColor = Color.White; b.FlatStyle = FlatStyle.Flat; b.FlatAppearance.BorderSize = 0; }
        b.Click += (_, _) => onClick();
        return b;
    }

    public static TextBox Input(string placeholder, int width, Action<string>? onEnter = null)
    {
        var t = new TextBox { Width = width, Font = Base, PlaceholderText = placeholder, Margin = new Padding(0, 2, 0, 2) };
        if (onEnter != null)
            t.KeyDown += (_, e) =>
            {
                if (e.KeyCode != Keys.Enter) return;
                e.SuppressKeyPress = true;
                onEnter(t.Text);
            };
        return t;
    }

    public static FlowLayoutPanel Column(int width = 0) => new()
    {
        FlowDirection = FlowDirection.TopDown,
        WrapContents = false,
        AutoSize = true,
        AutoSizeMode = AutoSizeMode.GrowAndShrink,
        MinimumSize = width > 0 ? new Size(width, 0) : Size.Empty,
        Margin = new Padding(0),
    };

    public static FlowLayoutPanel Row() => new()
    {
        FlowDirection = FlowDirection.LeftToRight,
        WrapContents = false,
        AutoSize = true,
        AutoSizeMode = AutoSizeMode.GrowAndShrink,
        Margin = new Padding(0, 2, 0, 2),
    };

    /// 연한 배경의 카드 (제목 + 내용)
    public static FlowLayoutPanel Card(string title, int width)
    {
        var c = Column(width);
        c.BackColor = CardBack;
        c.Padding = new Padding(12);
        c.Margin = new Padding(0, 6, 0, 6);
        if (title.Length > 0) c.Controls.Add(Text(title, Bold));
        return c;
    }

    /// 숫자 큰 칸 (공부 시간 등)
    public static Control Kpi(string value, string label, int width)
    {
        var c = Card("", width);
        c.Controls.Add(Text(value, new Font("Segoe UI", 15f, FontStyle.Bold)));
        c.Controls.Add(Text(label, Small, Muted));
        return c;
    }
}

/// 모든 창의 바탕: 1초마다 / 기록이 바뀔 때 RefreshView 가 불린다.
/// dataChanged 가 true 일 때만 목록을 다시 만든다 (입력 중인 칸이 사라지지 않게 입력 칸은 목록 밖에 둔다).
abstract class AppWindow : Form
{
    protected readonly Controller App;
    protected Store Store => App.Store;
    protected static string L(string ko, string en) => I18n.L(ko, en);

    protected AppWindow(Controller app, string title)
    {
        App = app;
        Text = title;
        Font = Ui.Base;
        AutoScaleMode = AutoScaleMode.Dpi;
        StartPosition = FormStartPosition.CenterScreen;
        Padding = new Padding(16);
        Icon = Controller.AppIcon;
        KeyPreview = true;
    }

    public abstract void RefreshView(bool dataChanged);
}

/// 할 일 한 줄: 동그라미 눌러 체크, 글자 더블 클릭해서 고치기 (Enter 저장 · Esc 취소), 마우스를 올리면 삭제 버튼
sealed class TodoRow : FlowLayoutPanel
{
    public TodoRow(Store store, TodoItem item, string day, int width, Action onEditStart, Action onEditEnd)
    {
        FlowDirection = FlowDirection.LeftToRight;
        WrapContents = false;
        AutoSize = true;
        Margin = new Padding(0, 1, 0, 1);
        var check = new Label
        {
            Text = item.Done ? "☑" : "☐",
            Font = new Font("Segoe UI Symbol", 13f),
            ForeColor = item.Done ? Ui.KindColor(item.Kind) : Ui.Muted,
            AutoSize = true,
            Cursor = Cursors.Hand,
            Margin = new Padding(0, 0, 4, 0),
        };
        check.Click += (_, _) => store.ToggleTodo(item.Id, day);
        var text = Ui.Text(item.Text, item.Done ? new Font(Ui.Base, FontStyle.Strikeout) : Ui.Base, item.Done ? Ui.Muted : null, width - 70);
        text.Margin = new Padding(0, 5, 4, 0);
        var del = new Label { Text = "🗑", Font = Ui.Base, ForeColor = Ui.Muted, AutoSize = true, Cursor = Cursors.Hand, Visible = false, Margin = new Padding(0, 5, 0, 0) };
        del.Click += (_, _) => store.DeleteTodo(item.Id, day);
        new ToolTip().SetToolTip(text, I18n.L("더블 클릭해서 고치기", "Double-click to edit"));

        text.DoubleClick += (_, _) =>
        {
            onEditStart();
            var box = new TextBox { Text = item.Text, Width = width - 70, Font = Ui.Base };
            var done = false;
            void finish(bool save)
            {
                if (done) return;
                done = true;
                if (save) store.RenameTodo(item.Id, box.Text, day); // 비우면 원래 글 유지
                onEditEnd();
            }
            box.KeyDown += (_, e) =>
            {
                if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; finish(true); }
                else if (e.KeyCode == Keys.Escape) { e.SuppressKeyPress = true; finish(false); }
            };
            box.LostFocus += (_, _) => finish(true);
            Controls.Remove(text);
            Controls.Add(box);
            Controls.SetChildIndex(box, 1);
            box.Focus();
            box.SelectAll();
        };
        void hover(bool on) => del.Visible = on;
        foreach (Control c in new Control[] { this, check, text, del })
        {
            c.MouseEnter += (_, _) => hover(true);
            c.MouseLeave += (_, _) => { if (!ClientRectangle.Contains(PointToClient(Cursor.Position))) hover(false); };
        }
        Controls.Add(check);
        Controls.Add(text);
        Controls.Add(del);
    }
}
