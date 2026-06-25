// ============================================================================
// Blockfall — Guide companion (additive AI helper, prototype)
//
// A friendly in-game "Guide" kids (7-10) can ask questions like:
//   "how do I make a pickaxe?", "what do I do at night?", "what's that animal?"
//
// This is a PURE ADDITIVE UI LAYER. It touches no game/engine code, makes no
// ABI calls, and captures no game input beyond a single 'G' hotkey to toggle
// its own chat panel.
//
// On-device intelligence:
//   * If Apple's Foundation Models framework + an available system model are
//     present (macOS 26+, Apple Intelligence enabled), answers are generated
//     on-device via a LanguageModelSession — leveraging the Neural Engine, no
//     network, no data leaving the Mac.
//   * Otherwise it falls back to a small rule-based responder so the Guide is
//     ALWAYS useful, even on older OSes / Macs without Apple Intelligence.
//
// The Foundation Models dependency is fully soft: `#if canImport` plus
// `@available` guards mean there are NO hard references to the framework when
// it is absent, so the project compiles and runs on toolchains without it.
// ============================================================================
import AppKit

#if canImport(FoundationModels)
import FoundationModels
#endif

// ---------------------------------------------------------------------------
// Kid-friendly system instruction describing Blockfall. Shared by the model
// session; the fallback responder embeds the same world knowledge in its rules.
// ---------------------------------------------------------------------------
private let kGuideSystemInstruction = """
You are "Guide", a cheerful, patient helper inside a video game called Blockfall.

ABOUT BLOCKFALL — these are the ONLY facts about the game. Do NOT invent items, blocks, \
recipes, creatures, or mechanics that are not listed here.
- Blockfall is a friendly voxel sandbox where you mine blocks, craft tools, and build.
- THE STORY: the world has lost its colors. A grey called the Dim Barrens (also "the Grey") \
spreads and drains color away. Light pushes the grey back. Long ago, glowing beacons kept \
the world bright, but they went dark. Your job is to bring color back by making light and \
relighting the beacons.
- GETTING STARTED: chop a tree to get logs, turn logs into wooden planks, turn planks into \
sticks, and craft a crafting table from planks. You craft tools on the crafting table.
- TOOLS: a pickaxe mines stone and ore, an axe chops wood fast, a shovel digs dirt and sand, \
and a sword helps at night. Tools come in wood, then stone, then iron (each one stronger). \
You make a tool from sticks plus planks, stone, or iron on a crafting table.
- MINING AND ORES: dig downward to find ores. Coal and copper are nearer the top; iron and \
rare sparkly crystal are deeper. Mine ore with a pickaxe. Raw iron becomes iron bars to craft with.
- LIGHT AND COLOR: craft torches from a stick and coal and place them to light dark places and \
push back the grey. Crystal makes color dust and crystal shards. Beacons are built from crystal \
shards and iron, and lighting beacons brings color back to the world.
- DAY AND NIGHT: friendly animals roam in the daytime. At night gentle monsters come out, so \
build a small shelter or dig into a hill and place torches to stay safe until morning.
- VILLAGERS: friendly villagers like Elder Mira live in villages and give helpful quests.
- FOOD AND PLANTS: berry bushes drop berry clusters, and forests and swamps have mushrooms. \
You CAN eat berries and mushrooms, and cook mushroom stew and honey cake. Berries also feed \
animals. Flowers, tall grass, reeds, lily pads, cactus, and seashells decorate the world. \
(Yes, berries exist in Blockfall.)
- ANIMALS: friendly animals such as woolly lambs roam by day. Feed a berry to an animal to \
befriend it.
- HELP KEY: a player can press G at any time to open you, the Guide.

You are talking to a child who is 7 to 10 years old. Always:
- Answer in 1 to 3 short, simple sentences a young kid can read.
- Be warm, encouraging, and fun. A little excitement is great.
- Give a clear next step they can actually do in the game.
- Use ONLY the facts above. If you are not sure, or it is not in the facts, say you are not \
sure and suggest something simple like chopping wood or making a crafting table. Never make \
up items, recipes, or mechanics.
- Never mention anything scary or violent beyond the gentle "monsters come at night, so build a shelter" idea.
"""

// Shown once at the top of the transcript.
private let kGuideGreeting =
    "Hi! I'm your Guide. Ask me anything about Blockfall — like \"how do I make a pickaxe?\" 🛠️"

final class GuideController: NSObject {

    // The floating chat window (lazily built the first time the Guide opens).
    private var panel: NSPanel?
    private weak var transcriptView: NSTextView?
    private weak var inputField: NSTextField?
    private weak var sendButton: NSButton?
    private weak var statusLabel: NSTextField?

    // Local key monitor; removed on deinit to avoid leaks.
    private var keyMonitor: Any?

    // Guards against overlapping requests (kids may mash Send).
    private var isThinking = false

    // The on-device model session, if Foundation Models is available. Stored as
    // `Any?` so this property has no hard type reference to the framework when it
    // is absent — keeps the build safe. Cast back behind @available at use sites.
    private var modelSessionBox: Any?

    override init() {
        super.init()
        installKeyMonitor()
        prepareModelIfAvailable()
    }

    deinit {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: - Key monitor (toggle with 'G', close with Esc)

    private func installKeyMonitor() {
        // Local monitor: only sees events for this app, and we return the event
        // unchanged for anything we don't handle so the game keeps all its keys.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // Don't steal keys while the user is typing into a text field anywhere
        // (including our own input field) — let normal text editing happen.
        if isEditingText() {
            // Exception: Esc should still close our panel even from the field.
            if event.keyCode == 53, panel?.isVisible == true {
                closePanel()
                return nil
            }
            return event
        }

        switch event.keyCode {
        case 5: // 'G' — toggle the Guide panel
            togglePanel()
            return nil // swallow so the game doesn't also see this 'G'
        case 53: // Esc — close the panel if it's open (otherwise pass through)
            if panel?.isVisible == true {
                closePanel()
                return nil
            }
            return event
        default:
            return event
        }
    }

    // True when the current first responder is a text field / text view being
    // edited, so we leave keyboard input alone.
    private func isEditingText() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSTextView { return true }
        if let tv = responder as? NSTextView, tv.isFieldEditor { return true }
        // NSTextField uses a shared field editor (an NSText/NSTextView) while editing,
        // but can also be the responder itself before the editor is installed — both
        // count as "typing" so 'G' doesn't close the panel mid-question.
        if responder is NSText { return true }
        if responder is NSTextField { return true }
        return false
    }

    // MARK: - Panel lifecycle

    private func togglePanel() {
        if panel?.isVisible == true {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        let p = panel ?? buildPanel()
        panel = p
        p.makeKeyAndOrderFront(nil)
        // Focus the input so kids can just start typing.
        if let field = inputField {
            p.makeFirstResponder(field)
        }
    }

    private func closePanel() {
        panel?.orderOut(nil)
        // Hand focus back to the game window so movement keys work again.
        if let main = NSApp.windows.first(where: { $0 != panel && $0.isVisible }) {
            main.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - UI construction (kid-friendly: rounded, big text)

    private func buildPanel() -> NSPanel {
        let size = NSSize(width: 380, height: 460)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = "Guide"
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.level = .floating
        p.isReleasedWhenClosed = false

        // Root container with a soft rounded card look.
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.16, blue: 0.22, alpha: 1).cgColor
        root.layer?.cornerRadius = 16

        // --- Transcript (scrollable, big readable text) ---
        let scroll = NSScrollView(frame: NSRect(x: 14, y: 70, width: size.width - 28, height: size.height - 110))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 12
        scroll.layer?.masksToBounds = true

        let text = NSTextView(frame: scroll.bounds)
        text.autoresizingMask = [.width]
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = true
        text.backgroundColor = NSColor(srgbRed: 0.16, green: 0.21, blue: 0.28, alpha: 1)
        text.textColor = .white
        text.font = NSFont.systemFont(ofSize: 16)
        text.textContainerInset = NSSize(width: 10, height: 10)
        scroll.documentView = text
        transcriptView = text
        root.addSubview(scroll)

        // --- Status line ("Thinking…" / which brain is active) ---
        let status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: 16, y: 44, width: size.width - 32, height: 18)
        status.autoresizingMask = [.width, .minYMargin]
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = NSColor.white.withAlphaComponent(0.55)
        status.stringValue = guideBackendDescription()
        root.addSubview(status)
        statusLabel = status

        // --- Input field ---
        let field = GuideTextField(frame: NSRect(x: 14, y: 12, width: size.width - 92, height: 30))
        field.autoresizingMask = [.width, .maxYMargin]
        field.placeholderString = "Ask me a question…"
        field.font = NSFont.systemFont(ofSize: 15)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.target = self
        field.action = #selector(sendTapped) // fires on Return
        root.addSubview(field)
        inputField = field

        // --- Send button ---
        let send = NSButton(title: "Send", target: self, action: #selector(sendTapped))
        send.frame = NSRect(x: size.width - 72, y: 11, width: 58, height: 32)
        send.autoresizingMask = [.minXMargin, .maxYMargin]
        send.bezelStyle = .rounded
        send.keyEquivalent = "\r"
        send.font = NSFont.boldSystemFont(ofSize: 14)
        root.addSubview(send)
        sendButton = send

        p.contentView = root
        p.center()

        // Seed the transcript with a friendly greeting.
        appendLine(speaker: "Guide", text: kGuideGreeting)

        return p
    }

    // MARK: - Sending / answering

    @objc private func sendTapped() {
        guard !isThinking else { return }
        guard let field = inputField else { return }
        let question = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        field.stringValue = ""
        appendLine(speaker: "You", text: question)
        setThinking(true)

        Task { [weak self] in
            guard let self else { return }
            let answer = await self.answer(for: question)
            await MainActor.run {
                self.appendLine(speaker: "Guide", text: answer)
                self.setThinking(false)
            }
        }
    }

    private func setThinking(_ on: Bool) {
        isThinking = on
        sendButton?.isEnabled = !on
        statusLabel?.stringValue = on ? "Thinking… 🤔" : guideBackendDescription()
    }

    // Produce an answer, preferring the on-device model and falling back to the
    // rule-based responder on any failure or when the model is unavailable.
    private func answer(for question: String) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), let session = modelSessionBox as? LanguageModelSession {
            do {
                let response = try await session.respond(to: question)
                let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty { return content }
            } catch {
                // Fall through to the rule-based responder on any model error.
                NSLog("Blockfall Guide: model error, using fallback — \(error)")
            }
        }
        #endif
        return Self.ruleBasedAnswer(for: question)
    }

    // MARK: - Foundation Models setup (soft dependency)

    private func prepareModelIfAvailable() {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard SystemLanguageModel.default.availability == .available else { return }
            let instructions = Instructions(kGuideSystemInstruction)
            modelSessionBox = LanguageModelSession(instructions: instructions)
        }
        #endif
    }

    // Human-readable note about which "brain" is answering.
    private func guideBackendDescription() -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), modelSessionBox != nil {
            return "On-device AI • private, no internet"
        }
        #endif
        return "Helper mode • built-in tips"
    }

    // MARK: - Transcript helpers

    private func appendLine(speaker: String, text: String) {
        guard let tv = transcriptView, let storage = tv.textStorage else { return }
        let isGuide = (speaker == "Guide")
        let nameColor = isGuide
            ? NSColor(srgbRed: 0.55, green: 0.85, blue: 1.0, alpha: 1)
            : NSColor(srgbRed: 1.0, green: 0.86, blue: 0.40, alpha: 1)

        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 10
        para.lineSpacing = 2

        let prefix = NSAttributedString(string: "\(speaker): ", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 16),
            .foregroundColor: nameColor,
            .paragraphStyle: para,
        ])
        let body = NSAttributedString(string: "\(text)\n", attributes: [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.white,
            .paragraphStyle: para,
        ])

        if storage.length > 0 {
            storage.append(NSAttributedString(string: "\n"))
        }
        storage.append(prefix)
        storage.append(body)
        tv.scrollToEndOfDocument(nil)
    }

    // MARK: - Rule-based fallback responder

    // Keyword-matches common kid questions. Always returns something helpful.
    static func ruleBasedAnswer(for raw: String) -> String {
        let q = raw.lowercased()
        func has(_ words: String...) -> Bool { words.contains { q.contains($0) } }

        // Order matters: more specific topics first.
        if has("pickaxe", "pick axe") {
            return "To make a pickaxe, first chop some wood from a tree, turn it into planks, then make a crafting table. Put sticks and planks (or stone) on the table to craft your pickaxe! ⛏️"
        }
        if has("crafting table", "craft table", "workbench") {
            return "Punch a tree to get wood, turn it into wooden planks, then craft a crafting table from the planks. Place it down and you can build all kinds of tools! 🧰"
        }
        if has("axe") {
            return "An axe is great for chopping trees fast! Make a crafting table first, then combine sticks and planks (or stone) to craft your axe. 🪓"
        }
        if has("craft", "recipe", "make ", "build", "how do i make", "how to make") {
            return "Crafting is easy! Gather wood, make a crafting table, and combine items on it. Try crafting sticks and planks into a pickaxe or axe first. 🛠️"
        }
        if has("night", "dark", "sleep", "shelter") {
            return "When night comes, monsters appear! Quickly build a little shelter out of blocks, close it up, and stay safe until morning. ☀️ You can also dig into a hill to hide!"
        }
        if has("monster", "scary", "zombie", "enemy", "fight") {
            return "Monsters only come out at night. The safest plan is to build a shelter before dark so they can't reach you. Stay cozy until the sun comes up! 🌙"
        }
        if has("animal", "cow", "pig", "sheep", "chicken", "creature", "that animal") {
            return "Friendly animals roam around in the daytime — they're safe and fun to watch! You can build fences to keep them nearby. 🐮🐑"
        }
        if has("crystal") {
            return "Crystal is a rare, sparkly ore found deep underground. Dig down carefully with a good pickaxe and bring torches so you can see! ✨"
        }
        if has("iron") {
            return "Iron is a strong metal ore found deeper underground. Mine it with a stone pickaxe, and you can make even better tools with it! ⚙️"
        }
        if has("copper") {
            return "Copper is a shiny orange ore you'll find as you dig down. Grab a pickaxe and start mining to collect it! 🟠"
        }
        if has("coal") {
            return "Coal is a black ore that's great for torches to light up dark caves. Mine it with a pickaxe — it's usually not too deep! 🔥"
        }
        if has("ore", "mine", "mining", "dig", "underground", "cave") {
            return "Dig downward to find ores! Closer to the top you'll find coal and copper, and deeper down there's iron and rare crystal. Bring a pickaxe and some torches. ⛏️✨"
        }
        if has("water", "swim", "lake", "river", "ocean") {
            return "You can swim in water, but be careful not to stay under too long! Water is great for making lakes and waterfalls when you build. 💧"
        }
        if has("tree", "wood", "log", "plank") {
            return "Trees give you wood — punch or chop one to collect logs. Turn logs into planks, and planks into sticks. Wood is the start of almost everything! 🌳"
        }
        if has("torch", "light", "lamp") {
            return "Torches light up dark places like caves. Make them from sticks and coal, then place them on walls to keep monsters away. 🔦"
        }
        if has("grey", "gray", "colour", "color", "dim barren", "barren", "drain", "dull") {
            return "The world lost its colors to the grey! Light pushes it back — place torches and relight the old beacons to bring color home. ✨"
        }
        if has("beacon") {
            return "Beacons are special lights that bring color back! Build one from crystal shards and iron, then light it to heal the grey. 🔆"
        }
        if has("villager", "elder", "mira", "village", "npc", "quest", "task", "talk") {
            return "Friendly villagers like Elder Mira live in villages and give you helpful quests. Talk to them to find your next adventure! 🧑‍🌾"
        }
        if has("achievement", "trophy", "reward", "goal", "unlock") {
            return "You earn achievements by exploring, mining, and building cool things! Keep adventuring and you'll unlock lots of them. 🏆"
        }
        if has("hello", "hi ", "hey", "hi!") || q == "hi" {
            return "Hi there! 👋 I'm your Guide. Ask me how to craft tools, what to do at night, or anything about Blockfall!"
        }
        if has("what do i do", "what now", "stuck", "help", "start", "begin", "how do i") {
            return "Great question! Start by punching a tree to get wood, then make a crafting table. From there you can craft tools and start building. 🌟"
        }

        // Generic, always-helpful default.
        return "Hmm, let me help! A great way to start is to mine some wood from a tree, then make a crafting table. From there you can craft tools and build anything you imagine! 🌳🛠️"
    }
}

// A text field whose Esc key closes the Guide via the panel's responder chain
// instead of clearing the field, and that doesn't beep on Return.
private final class GuideTextField: NSTextField {
    override func cancelOperation(_ sender: Any?) {
        window?.orderOut(nil)
    }
}
