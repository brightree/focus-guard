using System.Globalization;

namespace FocusGuard.Core;

/// 화면 문구: 설정한 언어에 맞는 쪽을 고른다
public static class I18n
{
    public static Lang Current { get; set; } = SystemLang;

    /// 처음 켤 때는 컴퓨터의 언어를 따른다
    public static Lang SystemLang => CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ko" ? Lang.Ko : Lang.En;

    public static string L(string ko, string en) => Current == Lang.En ? en : ko;

    public static CultureInfo Culture => CultureInfo.GetCultureInfo(Current == Lang.En ? "en-US" : "ko-KR");
}

public static class Fmt
{
    /// "yyyy-MM-dd" (이 컴퓨터 시간대 기준)
    public static string DayKey(DateTime d) => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    public static DateTime? ParseDay(string key) =>
        DateTime.TryParseExact(key, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d : null;

    public static string Minutes(double sec)
    {
        var m = (int)Math.Round(sec / 60);
        if (I18n.Current == Lang.En) return m >= 60 ? $"{m / 60}h {m % 60}m" : $"{m} min";
        return m >= 60 ? $"{m / 60}시간 {m % 60}분" : $"{m}분";
    }

    public static string Clock(double sec)
    {
        var s = Math.Max(0, (int)Math.Round(sec));
        return $"{s / 60:00}:{s % 60:00}";
    }

    /// "10월 27일 화요일" / "Tuesday, October 27"
    public static string DayTitle(string key)
    {
        var d = ParseDay(key);
        if (d is null) return key;
        return I18n.Current == Lang.En
            ? d.Value.ToString("dddd, MMMM d", I18n.Culture)
            : d.Value.ToString("M월 d일 dddd", I18n.Culture);
    }

    /// 오늘 · 내일 · 어제 (그 외엔 null)
    public static string? Relative(string key, string today)
    {
        var d = ParseDay(key); var t = ParseDay(today);
        if (d is null || t is null) return null;
        return (int)(d.Value - t.Value).TotalDays switch
        {
            -1 => I18n.L("어제", "Yesterday"),
            0 => I18n.L("오늘", "Today"),
            1 => I18n.L("내일", "Tomorrow"),
            _ => null,
        };
    }

    public static string Weekday(DateTime d) =>
        (I18n.Current == Lang.En ? new[] { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" } : new[] { "일", "월", "화", "수", "목", "금", "토" })[(int)d.DayOfWeek];

    /// 그 주 월요일
    public static DateTime Monday(DateTime d) => d.Date.AddDays(-(((int)d.DayOfWeek + 6) % 7));
}

public static class SiteRules
{
    /// "https://www.youtube.com/watch?v=1", "youtube.com:443" 등에서 도메인만. 도메인이 아니면 null.
    public static string? NormalizeSite(string raw)
    {
        var s = (raw ?? "").Trim().ToLowerInvariant();
        if (s.Length == 0) return null;
        if (!s.Contains("://")) s = "https://" + s;
        if (!Uri.TryCreate(s, UriKind.Absolute, out var u)) return null;
        var host = u.Host;
        if (!host.Contains('.') || !host.All(c => char.IsLetterOrDigit(c) || c == '-' || c == '.')) return null;
        return host.StartsWith("www.") ? host[4..] : host;
    }

    /// 주소창 글자(스킴이 없을 수 있음)에서 통계용 도메인. 차단 페이지 같은 내 컴퓨터 주소는 뺀다.
    public static string? Domain(string url)
    {
        var s = (url ?? "").Trim();
        if (s.Length == 0 || s.Contains(' ')) return null; // 검색어
        if (!s.Contains("://")) s = "https://" + s;
        if (!Uri.TryCreate(s, UriKind.Absolute, out var u) || (u.Scheme != "http" && u.Scheme != "https")) return null;
        var host = u.Host.ToLowerInvariant();
        if (!host.Contains('.') || host == "127.0.0.1" || host == "localhost") return null;
        return host.StartsWith("www.") ? host[4..] : host;
    }

    /// 차단 목록에 있으면 그 사이트, 아니거나 허용 목록에 있으면 null
    public static string? Match(string? host, IEnumerable<string> sites, IEnumerable<string> allow)
    {
        if (host is null) return null;
        bool m(string site) => host == site || host.EndsWith("." + site);
        if (allow.Any(m)) return null;
        return sites.FirstOrDefault(m);
    }

    /// 비교할 때 띄어쓰기 · 문장부호 · 유니코드 조합 차이는 무시한다
    public static string NormalizePhrase(string s) =>
        new string((s ?? "").Normalize().Where(c => !char.IsWhiteSpace(c) && !char.IsPunctuation(c)).ToArray());
}
