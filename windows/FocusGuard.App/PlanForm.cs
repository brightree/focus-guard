using FocusGuard.Core;

namespace FocusGuard.App;

/// 할 일 창: ◀ 날짜 ▶ 이동, 반드시 / 하면 좋은 일 / 기타, 바로 체크 · 더블 클릭 수정 · 삭제, 지난번 못 한 일 가져오기
sealed class PlanForm : AppWindow
{
    const int W = 460;
    string day;
    bool editing;
    readonly Label title = Ui.Text("", Ui.Title), badge = Ui.Text("", Ui.Small, Ui.Blue), subtitle = Ui.Text("", null, Ui.Muted);
    readonly FlowLayoutPanel carry = Ui.Column(W);
    readonly Dictionary<TodoKind, (Label Head, FlowLayoutPanel Rows)> sections = new();
    readonly Button todayButton;

    public PlanForm(Controller app, string day) : base(app, I18n.L("할 일", "To-dos"))
    {
        this.day = day;
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        AutoScroll = true;
        Size = new Size(W + 60, 680);

        var root = Ui.Column(W);
        var nav = Ui.Row();
        nav.Controls.Add(Ui.Button("◀", () => MoveDay(-1)));
        var head = Ui.Column();
        var titleRow = Ui.Row();
        titleRow.Controls.Add(title);
        titleRow.Controls.Add(badge);
        head.Controls.Add(titleRow);
        head.Controls.Add(subtitle);
        nav.Controls.Add(head);
        nav.Controls.Add(Ui.Button("▶", () => MoveDay(1)));
        todayButton = Ui.Button(L("오늘", "Today"), () => SetDay(Store.TodayKey));
        nav.Controls.Add(todayButton);
        root.Controls.Add(nav);
        root.Controls.Add(carry);

        foreach (var kind in new[] { TodoKind.Must, TodoKind.Nice, TodoKind.Other })
        {
            var card = Ui.Card("", W);
            var h = Ui.Text("", Ui.Bold, Ui.KindColor(kind));
            var rows = Ui.Column(W - 24);
            var k = kind;
            var add = Ui.Input(Ui.KindPlaceholder(kind), W - 24, null);
            add.KeyDown += (_, e) =>
            {
                if (e.KeyCode != Keys.Enter) return;
                e.SuppressKeyPress = true;
                Store.AddTodo(add.Text, k, this.day);
                add.Text = "";
            };
            card.Controls.Add(h);
            card.Controls.Add(rows);
            card.Controls.Add(add);
            root.Controls.Add(card);
            sections[kind] = (h, rows);
        }
        Controls.Add(root);
    }

    public PlanForm SetDay(string d)
    {
        day = d;
        editing = false;
        RefreshView(true);
        return this;
    }

    void MoveDay(int delta)
    {
        if (Fmt.ParseDay(day) is DateTime d) SetDay(Fmt.DayKey(d.AddDays(delta)));
    }

    public override void RefreshView(bool dataChanged)
    {
        var today = Store.TodayKey;
        var todos = Store.TodosOn(day);
        var done = todos.Count(t => t.Done);
        title.Text = Fmt.DayTitle(day);
        badge.Text = Fmt.Relative(day, today) ?? "";
        todayButton.Visible = day != today;
        subtitle.Text = todos.Count > 0 ? L($"{todos.Count}개 중 {done}개 완료", $"{done} of {todos.Count} done")
                      : day == today ? L("오늘 할 일을 정해볼까요?", "What's on your plate today?")
                      : string.CompareOrdinal(day, today) > 0 ? L("이 날 할 일을 미리 적어둘까요?", "Plan this day ahead?")
                      : L("이 날은 적은 할 일이 없어요", "Nothing was planned for this day");
        if (!dataChanged || editing) return;

        carry.SuspendLayout();
        carry.Controls.Clear();
        var left = Store.UnfinishedBefore(day);
        if (string.CompareOrdinal(day, today) >= 0 && todos.Count == 0 && left.Count > 0)
        {
            var row = Ui.Row();
            row.BackColor = Color.FromArgb(253, 240, 224);
            row.Padding = new Padding(8);
            row.Controls.Add(Ui.Text(L($"지난번에 못 한 일 {left.Count}개가 있어요", $"{left.Count} left over from last time")));
            row.Controls.Add(Ui.Button(L("가져오기", "Bring Over"), () => Store.CarryOver(day)));
            carry.Controls.Add(row);
        }
        carry.ResumeLayout();

        foreach (var (kind, (head, rows)) in sections)
        {
            var items = todos.Where(t => t.Kind == kind).ToList();
            head.Text = Ui.KindTitle(kind) + (items.Count > 0 ? $"   {items.Count(t => t.Done)}/{items.Count}" : "");
            rows.SuspendLayout();
            rows.Controls.Clear();
            foreach (var item in items.Where(t => !t.Done).Concat(items.Where(t => t.Done))) // 끝낸 일은 아래로
                rows.Controls.Add(new TodoRow(Store, item, day, W - 24, () => editing = true, () => { editing = false; RefreshView(true); }));
            rows.ResumeLayout();
        }
    }
}
