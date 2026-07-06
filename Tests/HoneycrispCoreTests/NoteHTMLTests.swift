import Testing

@testable import HoneycrispCore

@Suite("Note HTML")
struct NoteHTMLTests {
    @Test("a title becomes the heading block and lines become divs")
    func titleAndBody() {
        #expect(
            NoteHTML.body(title: "Trip plan", text: "Day 1\n\nPack the tent")
                == "<div><h1>Trip plan</h1></div><div>Day 1</div><div><br></div><div>Pack the tent</div>"
        )
    }

    @Test("a title alone is just the heading")
    func titleOnly() {
        #expect(NoteHTML.body(title: "Trip plan", text: nil) == "<div><h1>Trip plan</h1></div>")
    }

    @Test("markup characters are escaped, not interpreted")
    func escaping() {
        #expect(
            NoteHTML.body(title: "Fish & chips <fresh>", text: "a > b")
                == "<div><h1>Fish &amp; chips &lt;fresh&gt;</h1></div><div>a &gt; b</div>")
    }

    @Test("append paragraphs carry no heading and keep line breaks")
    func paragraphs() {
        #expect(NoteHTML.paragraphs("first\nsecond") == "<div>first</div><div>second</div>")
        #expect(NoteHTML.paragraphs("one\r\ntwo") == "<div>one</div><div>two</div>")
    }
}
