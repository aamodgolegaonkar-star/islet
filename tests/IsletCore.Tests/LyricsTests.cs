using System.Text.Json;
using Islet.Core;
using Xunit;

namespace IsletCore.Tests;

public class LRCParserTests
{
    [Fact]
    public void ParsesBasicLinesAndEnds()
    {
        var lines = LRCParser.Parse("[ar:Coldplay]\n[00:01.50]Look at the stars\n[00:04.25]Look how they shine for you", 10);
        Assert.Equal(["Look at the stars", "Look how they shine for you"], lines.Select(l => l.Text));
        Assert.Equal(1.5, lines[0].Start);
        Assert.Equal(4.25, lines[0].End);
        Assert.Equal(10, lines[1].End);
    }

    [Fact]
    public void FractionDigitsAreScaled() =>
        Assert.Equal([1.5, 2.43, 3.123], LRCParser.Parse("[00:01.5]a\n[00:02.43]b\n[00:03.123]c").Select(l => l.Start));

    [Fact]
    public void MultipleTimestampsRepeatTheLine() =>
        Assert.Equal(["Chorus", "Verse", "Chorus"], LRCParser.Parse("[00:01.00][00:03.00]Chorus\n[00:02.00]Verse").Select(l => l.Text));

    [Fact]
    public void OffsetMovesLyricsEarlier() =>
        Assert.Equal([1.5, 2.5], LRCParser.Parse("[offset:+500]\n[00:02.00]a\n[00:03.00]b").Select(l => l.Start));

    [Fact]
    public void CrlfFilesParse() =>
        Assert.Equal(["a", "b"], LRCParser.Parse("[00:01.00]a\r\n[00:02.00]b\r\n").Select(l => l.Text));

    [Fact]
    public void WordTagsAreStripped()
    {
        var lines = LRCParser.Parse("[00:12.00]<00:12.00>Look <00:12.40>at <00:12.70>the");
        Assert.Equal([true, false], lines.Select(l => l.IsInterlude));
        Assert.Equal("Look at the", lines[^1].Text);
    }

    [Fact]
    public void GapsBecomeInterludes()
    {
        var lines = LRCParser.Parse("[00:08.00]First\n[00:10.00]Second\n[00:12.00]\n[00:22.00]Third", 30);
        Assert.Equal([true, false, false, true, false], lines.Select(l => l.IsInterlude));
        Assert.True(lines[0].Start == 0 && lines[0].End == 8);
        Assert.True(lines[3].Start == 12 && lines[3].End == 22);
        Assert.Equal([0, 1, 2, 3, 4], lines.Select(l => l.Id));
    }

    [Fact]
    public void ActiveIndexUsesSmallLead()
    {
        var lines = LRCParser.Parse("[00:01.00]a\n[00:05.00]b\n[00:09.00]c");
        Assert.Null(LRCParser.ActiveIndex(lines, 0.5));
        Assert.Equal(1, LRCParser.ActiveIndex(lines, 4.9));
        Assert.Equal(2, LRCParser.ActiveIndex(lines, 100));
    }
}

public class MusicTextTests
{
    [Fact]
    public void NormalizeDropsEditionNoise()
    {
        Assert.Equal("not like us", MusicText.Normalize("Not Like Us - Single"));
        Assert.Equal("parachutes", MusicText.Normalize("Parachutes (Deluxe Edition)"));
        Assert.Equal("beyonce", MusicText.Normalize("Beyoncé"));
        Assert.Equal("song", MusicText.Normalize("Song feat. Someone"));
    }

    [Fact]
    public void ArtworkUrlResizes() =>
        Assert.Equal("https://is1-ssl.mzstatic.com/image/thumb/Music/x/1400x1400bb.jpg",
            MusicText.ResizedArtworkUrl("https://is1-ssl.mzstatic.com/image/thumb/Music/x/100x100bb.jpg", 1400)?.AbsoluteUri);

    [Fact]
    public void AlbumSuffixCleanup()
    {
        Assert.Equal("Not Like Us", LRCLIBClient.CleanAlbum("Not Like Us - Single"));
        Assert.Equal("Parachutes", LRCLIBClient.CleanAlbum("Parachutes"));
    }

    [Theory]
    [InlineData("Here Comes the Sun - Remastered 2009", "Here Comes the Sun")]
    [InlineData("Stay (feat. Justin Bieber)", "Stay")]
    [InlineData("Blinding Lights", "Blinding Lights")]
    [InlineData("Bohemian Rhapsody - Live Aid", "Bohemian Rhapsody")]
    [InlineData("Creep [Explicit]", "Creep")]
    [InlineData("Levitating (Sped Up)", "Levitating")]
    [InlineData("Sunflower - Spider-Man: Into the Spider-Verse", "Sunflower - Spider-Man: Into the Spider-Verse")]
    [InlineData("Song ft. Someone", "Song")]
    public void CleansTitles(string raw, string clean) => Assert.Equal(clean, MusicText.LyricsTitle(raw));

    [Fact]
    public void FirstArtist()
    {
        Assert.Equal("Central Cee", MusicText.PrimaryArtist("Central Cee feat. Dave"));
        Assert.Equal("Post Malone", MusicText.PrimaryArtist("Post Malone, Swae Lee"));
        Assert.Equal("Calvin Harris", MusicText.PrimaryArtist("Calvin Harris x Dua Lipa"));
        Assert.Equal("Adele", MusicText.PrimaryArtist("Adele"));
    }

    [Fact]
    public void CacheKeyIsStableAndMatchesTheMac()
    {
        // The same key the Mac computes, so a cache folder could be shared.
        var key = LRCLIBClient.CacheKey("Yellow", "Coldplay", "Parachutes", 266.6);
        Assert.Equal(Convert.ToHexString(System.Security.Cryptography.SHA256.HashData("yellow|coldplay|parachutes|267"u8)).ToLowerInvariant(), key);
    }
}

public class MotionArtworkTests
{
    [Fact]
    public void ReadsEditorialVideoVariants()
    {
        var art = MotionArtwork.Parse("""{"data":[{"id":"1","attributes":{"name":"A","editorialVideo":{"motionDetailSquare":{"video":"https://example.com/sq.m3u8"},"motionDetailTall":{"video":"https://example.com/tall.m3u8"}}}}]}""");
        Assert.Equal("https://example.com/sq.m3u8", art?.Square?.AbsoluteUri);
        Assert.Equal("https://example.com/tall.m3u8", art?.Tall?.AbsoluteUri);
    }

    [Fact]
    public void AbsentFieldIsNull() => Assert.Null(MotionArtwork.Parse("""{"data":[{"id":"1","attributes":{"name":"A"}}]}"""));
}

public class WordTimingTests
{
    [Fact]
    public void EstimateSpreadsWordsAcrossTheLine()
    {
        var words = WordTiming.Estimate("Look at the stars", 10, 13);
        Assert.Equal(["Look", "at", "the", "stars"], words.Select(w => w.Text));
        Assert.Equal(10, words[0].Start);
        for (var i = 0; i + 1 < words.Count; i++) Assert.True(Math.Abs(words[i].End - words[i + 1].Start) < 1e-9);
        Assert.True(words[3].End - words[3].Start > words[1].End - words[1].Start);
        Assert.True(words[^1].End <= 13);
    }

    [Fact]
    public void EstimateKeepsANaturalPaceOnLongLines() => Assert.True(WordTiming.Estimate("Hey you", 0, 12)[^1].End < 2);

    [Fact]
    public void EstimateFitsShortLines() => Assert.True(WordTiming.Estimate("One two three four", 5, 5.6)[^1].End <= 5.6);

    [Fact]
    public void PiecesTouchingWithoutSpaceFormOneWord()
    {
        var words = WordTiming.Words([new(1, "beau", 1.2), new(1.2, "ti", 1.4), new(1.4, "ful", 1.9), new(2, " day", 2.5)], 3);
        Assert.Equal(["beautiful", "day"], words.Select(w => w.Text));
        Assert.True(words[0].Start == 1 && words[0].End == 1.9);
        Assert.True(words[1].Start == 2 && words[1].End == 2.5);
    }

    [Fact]
    public void FocusCountsWordsSung()
    {
        List<LyricWord> words = [new("a", 1, 2), new("b", 3, 4)];
        Assert.Equal(-1, WordTiming.Focus(words, 0.5));
        Assert.Equal(0.5, WordTiming.Focus(words, 1.5));
        Assert.Equal(1, WordTiming.Focus(words, 2.5));
        Assert.Equal(1.25, WordTiming.Focus(words, 3.25));
        Assert.Equal(2, WordTiming.Focus(words, 9));
        Assert.Equal(1, WordTiming.Progress(0, 1.25));
        Assert.Equal(0.25, WordTiming.Progress(1, 1.25));
        Assert.Equal(0, WordTiming.Progress(2, 1.25));
    }
}

public class LRCWordTests
{
    [Fact]
    public void EnhancedLRCKeepsTheSourcesWordTimes()
    {
        var line = LRCParser.Parse("[00:02.00]<00:02.00>Look <00:02.40>at <00:02.70>the<00:03.10>\n[00:05.00]Next")[0];
        Assert.Equal("Look at the", line.Text);
        Assert.True(line.HasExactWordTiming);
        Assert.Equal(["Look", "at", "the"], line.Words.Select(w => w.Text));
        Assert.Equal([2, 2.4, 2.7], line.Words.Select(w => w.Start));
        Assert.Equal(3.1, line.Words[^1].End);
    }

    [Fact]
    public void PlainLRCGetsEstimatedWords()
    {
        var line = LRCParser.Parse("[00:01.00]Look at the stars\n[00:04.00]Next")[0];
        Assert.False(line.HasExactWordTiming);
        Assert.Equal(["Look", "at", "the", "stars"], line.Words.Select(w => w.Text));
    }

    [Fact]
    public void RepeatedChorusShiftsWordTimes()
    {
        var chorus = LRCParser.Parse("[00:01.00][00:11.00]<00:01.00>La <00:01.50>la").Where(l => !l.IsInterlude).ToList();
        Assert.Equal([1, 1.5], chorus[0].Words.Select(w => w.Start));
        Assert.Equal([11, 11.5], chorus[1].Words.Select(w => w.Start));
    }

    [Fact]
    public void InterludesHaveNoWords()
    {
        var first = LRCParser.Parse("[00:10.00]Late start")[0];
        Assert.True(first.IsInterlude);
        Assert.Empty(first.Words);
    }
}

public class TTMLTests
{
    private const string WordTimed = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word" xml:lang="en">
        <head><metadata><ttm:agent type="person" xml:id="v1"/></metadata></head>
        <body dur="3:00.000">
        <div begin="1.000" end="9.000">
        <p begin="1.000" end="3.500" itunes:key="L1" ttm:agent="v1"><span begin="1.000" end="1.400">What</span> <span begin="1.400" end="1.700">a</span> <span begin="1.800" end="2.100">beau</span><span begin="2.100" end="2.300">ti</span><span begin="2.300" end="2.800">ful</span> <span begin="2.900" end="3.400">day</span><span ttm:role="x-bg" begin="3.000" end="3.400"><span begin="3.000" end="3.400">(oh)</span></span></p>
        <p begin="9.000" end="11.000" itunes:key="L2" ttm:agent="v1"><span begin="9.000" end="10.000">Again</span></p>
        </div>
        </body>
        </tt>
        """;

    [Fact]
    public void WordTimedLyrics()
    {
        var lines = TTMLParser.Parse(WordTimed);
        var sung = lines.Where(l => !l.IsInterlude).ToList();
        Assert.Equal(["What a beautiful day", "Again"], sung.Select(l => l.Text));
        var first = sung[0];
        Assert.True(first.HasExactWordTiming);
        Assert.Equal(["What", "a", "beautiful", "day"], first.Words.Select(w => w.Text));
        Assert.True(first.Words[2].Start == 1.8 && first.Words[2].End == 2.8);
        Assert.Equal(3.5, first.End);
        Assert.Equal([false, true, false], lines.Select(l => l.IsInterlude));
    }

    [Fact]
    public void LineTimedLyricsGetEstimatedWords()
    {
        var line = TTMLParser.Parse("""
            <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
            <p begin="00:01.000" end="00:04.000">Look at the stars</p>
            </div></body></tt>
            """)[0];
        Assert.Equal("Look at the stars", line.Text);
        Assert.False(line.HasExactWordTiming);
        Assert.Equal(4, line.Words.Count);
    }

    [Fact]
    public void UnsyncedLyricsGiveNothing() =>
        Assert.Empty(TTMLParser.Parse("""<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p>Just words</p></div></body></tt>"""));

    [Fact]
    public void BrokenXmlGivesNothing() => Assert.Empty(TTMLParser.Parse("<tt><body><p begin=\"1\">oops"));

    [Fact]
    public void TimeFormats()
    {
        Assert.Equal(13.4, TTMLParser.Seconds("13.4"));
        Assert.Equal(62.5, TTMLParser.Seconds("1:02.5"));
        Assert.Equal(3723.25, TTMLParser.Seconds("01:02:03.25"));
        Assert.Equal(4.5, TTMLParser.Seconds("4.5s"));
        Assert.Null(TTMLParser.Seconds(""));
    }

    [Fact]
    public void CatalogMatchingChecksTitleArtistAndLength()
    {
        List<AppleMusicLyricsClient.Song> songs =
        [
            new("1", "Yellow (Live)", "Coldplay", 400000), new("2", "Yellow", "Coldplay", 266000), new("3", "Yellow", "Someone Else", 266000),
        ];
        Assert.Equal("2", AppleMusicLyricsClient.BestMatch(songs, "Yellow", "Coldplay", 267));
        Assert.Null(AppleMusicLyricsClient.BestMatch(songs, "Clocks", "Coldplay", 267));
    }
}

public class WordSymbolsTests
{
    private readonly WordSymbols _symbols = new(
        new HashSet<string> { "heart", "heart.fill", "flame", "car", "bold", "list.dash", "tree", "moon.stars" },
        new Dictionary<string, string[]> { ["tree"] = ["forest"], ["list.dash"] = ["list"] },
        new Dictionary<string, string[]>
        {
            ["heart"] = ["health"], ["flame"] = ["nature"], ["car"] = ["transportation"],
            ["bold"] = ["textformatting"], ["list.dash"] = ["textformatting"], ["tree"] = ["nature"],
        });

    [Fact]
    public void CommonWordsPreferFilledSymbols()
    {
        Assert.Equal("heart.fill", _symbols.Symbol("Love"));
        Assert.Equal("flame", _symbols.Symbol("burning", "burn"));
        Assert.Equal("moon.stars", _symbols.Symbol("night", isNoun: true));
    }

    [Fact]
    public void OtherWordsMustBeEverydayNouns()
    {
        Assert.Equal("tree", _symbols.Symbol("forest", isNoun: true));
        Assert.Null(_symbols.Symbol("forest"));
        Assert.Null(_symbols.Symbol("bold", isNoun: true));
        Assert.Null(_symbols.Symbol("list", isNoun: true));
    }

    [Fact]
    public void ShortWordsAndPunctuation()
    {
        Assert.Equal("fire", WordSymbols.Clean("Fire!"));
        Assert.Equal("heart", WordSymbols.Clean("heart's"));
        Assert.Equal("heart", WordSymbols.Clean("heart’s"));
        Assert.Null(_symbols.Symbol("a", isNoun: true));
    }

    [Fact]
    public void SystemTableAnnotatesLyrics()
    {
        var words = WordSymbols.System.Annotate(LRCParser.Parse("[00:01.00]I see fire in the night sky, burning\n[00:05.00]End"))[0].Words;
        var found = words.Where(w => w.Symbol is not null).ToDictionary(w => w.Text, w => w.Symbol!);
        Assert.StartsWith("flame", found["fire"]);
        Assert.StartsWith("moon", found["night"]);
        Assert.StartsWith("flame", found["burning"]);
        Assert.False(found.ContainsKey("I") || found.ContainsKey("the"));
    }

    [Fact]
    public void PlayerButtonsAreNotPictures()
    {
        var words = WordSymbols.System.Annotate(LRCParser.Parse("[00:01.00]He keeps on playin' games with the play\n[00:05.00]End"))[0].Words;
        Assert.Null(words.First(w => w.Text == "play").Symbol);
        Assert.Null(words.First(w => w.Text == "playin'").Symbol);
    }
}

public class WordStreamTests
{
    private readonly WordStream _stream = new(LRCParser.Parse(
        "[00:01.00]<00:01.00>Now <00:01.50>when<00:02.00>\n[00:02.20]<00:02.20>you <00:02.60>see<00:03.00>\n[00:09.00]<00:09.00>Again<00:10.00>"));

    [Fact]
    public void WordsRunAcrossLines()
    {
        Assert.Equal(["Now", "when", "you", "see", "Again"], _stream.Words.Select(w => w.Text));
        Assert.Null(_stream.Index(0.5));
        Assert.Equal(1, _stream.Index(1.7));
        Assert.Equal(1, _stream.Index(2.1));
        Assert.Equal(2, _stream.Index(2.3));
    }

    [Fact]
    public void ClearsDuringLongGaps()
    {
        Assert.False(_stream.IsResting(2.1));
        Assert.True(_stream.IsResting(6));
        Assert.False(_stream.IsResting(8.7));
        Assert.True(_stream.IsResting(0.5));
    }
}
