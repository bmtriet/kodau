import Foundation

/// A candidate Vietnamese surface form with a relative prior weight.
public struct WeightedCandidate: Equatable, Sendable {
    public let surface: String
    public let weight: Double

    public init(surface: String, weight: Double) {
        self.surface = surface
        self.weight = weight
    }
}

/// Curated starter lexicon for offline Vietnamese diacritic restoration, English preservation,
/// and Vietnamese-English ambiguity resolution.
public enum SeedLexicon {

    // MARK: - English & Technical Loanwords (750+ words)

    /// Common English function/content words plus developer, office, and tech loanwords (lowercased).
    public static let englishWords: Set<String> = {
        let wordGroups: [String] = [
            // Core function words, pronouns, auxiliaries, prepositions, conjunctions
            """
            a an the is are was were be been being am have has had having do does did doing
            will would shall should can could may might must ought not no yes ok okay sure
            i me my mine myself you your yours yourself he him his himself she her hers herself
            it its itself we us our ours ourselves they them their theirs themselves
            this that these those who whom whose which what where when why how
            in on at to for of with by from up down into onto over under through between among
            about above across after against along around before behind below beneath beside
            beyond during except inside outside near off out past since toward towards upon within without
            and or but nor yet so because although though while whereas if unless until whether
            all any both each either every few many more most much neither none other another
            several some such same own very too quite rather really just only also even still already
            ever never always often usually sometimes rarely seldom soon now then than there here
            again back away well almost enough less least
            """,

            // High-frequency everyday verbs & inflections
            """
            go goes going went gone come comes coming came get gets getting got gotten
            make makes making made take takes taking took taken give gives giving gave given
            see sees seeing saw seen know knows knowing knew known think thinks thinking thought
            want wants wanting wanted need needs needing needed use uses using used
            find finds finding found tell tells telling told ask asks asking asked
            work works working worked seem seems seeming seemed feel feels feeling felt
            try tries trying tried leave leaves leaving left call calls calling called
            keep keeps keeping kept let lets letting begin begins beginning began begun
            help helps helping helped talk talks talking talked turn turns turning turned
            start starts starting started show shows showing showed shown hear hears hearing heard
            play plays playing played run runs running ran move moves moving moved
            live lives living lived believe believes believed bring brings bringing brought
            happen happens happened write writes writing wrote written provide provides provided
            sit sits sitting sat stand stands standing stood lose loses losing lost
            pay pays paying paid meet meets meeting met include includes including included
            continue continues continued set sets setting learn learns learning learned
            change changes changing changed lead leads leading led understand understands understood
            watch watches watching watched follow follows following followed stop stops stopping stopped
            create creates creating created speak speaks speaking spoke spoken read reads reading
            allow allows allowing allowed add adds adding added spend spends spending spent
            grow grows growing grew grown open opens opening opened walk walks walking walked
            win wins winning won offer offers offered remember remembers remembered love loves loved
            consider considers considered appear appears appeared buy buys buying bought
            wait waits waiting waited serve serves served die dies died send sends sending sent
            expect expects expected build builds building built stay stays staying stayed
            fall falls falling fell cut cuts cutting reach reaches reached kill kills killed
            remain remains remained suggest suggests raise pass passed sell require report decide
            pull pulls pulling pulled push pushes pushing pushed explain hope develop carry break
            receive agree support hit produce eat cover catch draw choose
            """,

            // High-frequency nouns, adjectives, greetings, time expressions
            """
            hello hi hey thanks thank please sorry excuse welcome goodbye bye cheers
            good great best better nice cool awesome fine bad worse worst
            new old young big small large little long short high low early late
            fast slow easy hard simple complex clear full empty free busy ready
            first second third last next previous final main top bottom left right
            true false real sure right wrong possible impossible important different similar
            public private local global internal external general special common normal standard
            time times day days week weeks month months year years hour hours minute minutes second seconds
            today tomorrow yesterday morning afternoon evening night tonight weekend
            people person man men woman women child children family friend friends group
            world country city home house room office company school life hand part place case
            point fact way thing things problem problems question questions answer answers
            idea ideas story book paper water food money number numbers name names word words
            line lines side head eye face body voice power order level area state
            """,

            // Tech, software engineering, macOS, AI/LLM, and office loanwords
            """
            code coding coder bug bugs fix fixes fixing fixed build builds building
            test tests testing tested deploy deploys deploying deployed deployment
            merge merges merging merged commit commits committing committed
            push pushes pushing pushed pull pulls pulling pulled
            branch branches repo repository git github gitlab bitbucket
            api apis key keys app apps web website frontend backend fullstack
            server servers client clients database db sql sqlite postgres mysql redis mongo
            json yaml xml html css scss js ts javascript typescript
            swift swiftui xcode cocoa objective python rust golang java kotlin react vue angular node npm
            docker kubernetes k8s container pod cluster cloud aws gcp azure vercel netlify
            model models prompt prompts agent agents ai llm gemini gpt claude openai flash pro
            mac macos ios iphone ipad apple watchos xcode safari finder spotlight
            google chrome firefox arc slack discord teams zoom meet meeting meetings
            email emails mail gmail calendar drive file files folder folders path directory
            link links url uri http https rest graphql grpc webhook socket
            doc docs document documents sheet sheets slide slides deck pdf csv markdown
            task tasks ticket tickets issue issues sprint backlog roadmap milestone
            deadline report reports review reviews reviewing reviewed feedback comment comments
            update updates updating updated upgrade release releases version versions
            feature features design figma sketch prototype wireframe layout
            prod production staging dev development qa sandbox preview
            debug debugging debugger log logs logging trace stack error errors exception crash warning
            config configuration setting settings env environment variable param parameter option options
            user users account login logout signin signup auth oauth token tokens session cookie
            password secret keystroke keyboard shortcut hotkey command control shift option
            admin role permission access security privacy encrypt decrypt hash
            team teams member manager lead founder engineer developer designer product
            project projects plan planning goal goals okr kpi metric metrics status
            check checks checking checked done pending todo wip draft note notes
            chat message messages reply thread channel inbox notification alert
            sync async await thread queue lock mutex cache caching buffer stream
            offline online remote network latency bandwidth timeout retry fallback
            performance benchmark profile memory ram cpu gpu disk storage
            ui ux theme dark light mode view views screen window dialog modal popup popover
            menu menubar toolbar sidebar tab tabs panel card list grid table form
            button buttons input output cursor caret scroll click hover drag drop select copy paste undo redo
            import export backup restore reset install uninstall setup onboarding
            search filter sort query index schema migration query
            train training dataset fine-tune inference embedding vector token latency accuracy
            request requests response payload header body statuscode endpoint route
            package library framework sdk cli script terminal shell bash zsh
            """
        ]

        var set = Set<String>()
        set.reserveCapacity(850)
        for group in wordGroups {
            for token in group.split(whereSeparator: \.isWhitespace) {
                set.insert(String(token).lowercased())
            }
        }
        return set
    }()

    // MARK: - Ambiguous English / Vietnamese Words

    /// Words that are both common English words and common Vietnamese syllables (lowercased).
    public static let ambiguousEnViWords: Set<String> = [
        // Explicitly frequent cross-lingual collisions
        "a", "am", "an", "at", "ban", "bat", "bay", "be", "bit", "but",
        "cam", "can", "cap", "cat", "chat", "co", "con", "cup", "cut",
        "dam", "day", "do", "doc", "em", "go", "got",
        "ha", "ham", "hat", "hay", "he", "hi", "hit", "ho", "hop", "hot",
        "i", "in", "it",
        "la", "lam", "lap", "lay", "let", "lo", "lot", "lu",
        "ma", "mac", "man", "map", "mat", "may", "me", "men", "met", "mi", "min", "mo", "mu", "my",
        "na", "nam", "net", "ni", "no", "not", "nu",
        "on",
        "pa", "pi", "pin", "po",
        "ra", "ram", "rat", "run",
        "sa", "sat", "say", "set", "si", "sit", "so", "son", "su", "sun",
        "ta", "tan", "tap", "ten", "than", "that", "the", "them", "then", "ti", "tin", "tip", "to", "ton", "top", "tu",
        "up",
        "van", "vi", "vo", "vu",
        "xa", "xe"
    ]

    // MARK: - Vietnamese Unigram Lexicon (550+ Syllables)

    /// Starter unigram lexicon mapping ASCII base syllable -> ranked diacritic candidates.
    public static let vietnameseUnigrams: [String: [WeightedCandidate]] = {
        var map: [String: [WeightedCandidate]] = [:]
        map.reserveCapacity(650)

        func add(_ base: String, _ items: [(String, Double)]) {
            map[base] = items.map { WeightedCandidate(surface: $0.0, weight: $0.1) }
        }

        // --- 1. Pronouns, Demonstratives, Core Function Words & Particles ---
        add("toi", [("tôi", 1.0), ("tối", 0.55), ("tới", 0.50), ("tội", 0.20), ("tồi", 0.15)])
        add("ban", [("bạn", 1.0), ("bản", 0.72), ("bàn", 0.68), ("bán", 0.62), ("ban", 0.45), ("bận", 0.42), ("bắn", 0.22), ("bẩn", 0.18)])
        add("minh", [("mình", 1.0), ("minh", 0.55)])
        add("anh", [("anh", 1.0), ("ảnh", 0.60), ("ánh", 0.35)])
        add("em", [("em", 1.0), ("êm", 0.30)])
        add("chi", [("chỉ", 1.0), ("chị", 0.85), ("chi", 0.45), ("chí", 0.35), ("chì", 0.18)])
        add("chung", [("chúng", 1.0), ("chung", 0.75), ("chứng", 0.50), ("chủng", 0.25), ("chừng", 0.25), ("chưng", 0.15)])
        add("ta", [("ta", 1.0), ("tả", 0.35), ("tạ", 0.25), ("tá", 0.20), ("tà", 0.15)])
        add("ho", [("họ", 1.0), ("hỗ", 0.55), ("hồ", 0.45), ("hộ", 0.40), ("hô", 0.30), ("hở", 0.25), ("ho", 0.20), ("hớ", 0.15)])
        add("no", [("nó", 1.0), ("nợ", 0.45), ("nở", 0.35), ("nổ", 0.35), ("no", 0.30), ("nỗ", 0.25), ("nộ", 0.15)])
        add("ong", [("ông", 1.0), ("ống", 0.35), ("ong", 0.20), ("ỏng", 0.10)])
        add("ba", [("ba", 1.0), ("bà", 0.85), ("bá", 0.30), ("bã", 0.15), ("bả", 0.15)])
        add("co", [("có", 1.0), ("cô", 0.65), ("cơ", 0.60), ("cố", 0.50), ("cổ", 0.40), ("cỡ", 0.30), ("cờ", 0.25), ("co", 0.20), ("cỏ", 0.20)])
        add("chu", [("chú", 1.0), ("chủ", 0.90), ("chữ", 0.85), ("chứ", 0.75), ("chừ", 0.20), ("chu", 0.25), ("chù", 0.15)])
        add("bac", [("bác", 1.0), ("bắc", 0.65), ("bạc", 0.50), ("bậc", 0.45)])
        add("chau", [("cháu", 1.0), ("châu", 0.65), ("chậu", 0.25)])
        add("con", [("còn", 1.0), ("con", 0.90), ("cơn", 0.35), ("cồn", 0.20), ("cộn", 0.10)])
        add("ai", [("ai", 1.0), ("ái", 0.30), ("ải", 0.15)])
        add("gi", [("gì", 1.0), ("gỉ", 0.10)])
        add("nao", [("nào", 1.0), ("não", 0.45), ("náo", 0.20), ("nạo", 0.15)])
        add("nay", [("này", 1.0), ("nay", 0.55), ("nảy", 0.18), ("nãy", 0.16)])
        add("do", [("đó", 1.0), ("do", 0.82), ("độ", 0.72), ("đồ", 0.65), ("đỏ", 0.50), ("đổ", 0.45), ("đỡ", 0.42), ("đo", 0.35), ("dò", 0.25), ("dở", 0.25)])
        add("kia", [("kia", 1.0), ("kìa", 0.35)])
        add("day", [("đây", 1.0), ("đầy", 0.72), ("dạy", 0.65), ("dậy", 0.55), ("đẩy", 0.50), ("dây", 0.45), ("dày", 0.35), ("đáy", 0.30), ("đấy", 0.60)])
        add("o", [("ở", 1.0), ("ô", 0.55), ("ổ", 0.45), ("ơ", 0.35), ("ồ", 0.25), ("ờ", 0.25), ("ố", 0.20), ("ọ", 0.10)])
        add("la", [("là", 1.0), ("lạ", 0.45), ("lá", 0.40), ("la", 0.30), ("lã", 0.15), ("lả", 0.12)])
        add("khong", [("không", 1.0), ("khổng", 0.15), ("khống", 0.12)])
        add("duoc", [("được", 1.0), ("dược", 0.25), ("đuốc", 0.15)])
        add("se", [("sẽ", 1.0), ("sẻ", 0.35), ("se", 0.20)])
        add("da", [("đã", 1.0), ("đa", 0.65), ("đá", 0.55), ("da", 0.45), ("đà", 0.40), ("dạ", 0.40), ("đả", 0.20)])
        add("dang", [("đang", 1.0), ("đáng", 0.62), ("đăng", 0.58), ("dạng", 0.52), ("đằng", 0.35), ("đắng", 0.25), ("dáng", 0.25), ("đảng", 0.22)])
        add("rat", [("rất", 1.0), ("rát", 0.15)])
        add("qua", [("quá", 1.0), ("qua", 0.85), ("quả", 0.70), ("quà", 0.50)])
        add("nhieu", [("nhiều", 1.0), ("nhiễu", 0.18), ("nhiêu", 0.45)])
        add("it", [("ít", 1.0), ("ịt", 0.05)])
        add("hon", [("hơn", 1.0), ("hồn", 0.35), ("hôn", 0.30), ("hỗn", 0.20), ("hờn", 0.15)])
        add("nhat", [("nhất", 1.0), ("nhật", 0.65), ("nhạt", 0.35), ("nhặt", 0.35), ("nhát", 0.25)])
        add("voi", [("với", 1.0), ("vội", 0.45), ("vời", 0.40), ("vòi", 0.25), ("voi", 0.25), ("vơi", 0.20), ("vôi", 0.15)])
        add("va", [("và", 1.0), ("va", 0.20), ("vá", 0.15), ("vả", 0.12)])
        add("hoac", [("hoặc", 1.0)])
        add("nhung", [("nhưng", 1.0), ("những", 0.92), ("nhung", 0.25), ("nhúng", 0.25), ("nhũng", 0.12)])
        add("vi", [("vì", 1.0), ("vị", 0.72), ("vi", 0.55), ("ví", 0.50), ("vĩ", 0.35)])
        add("nen", [("nên", 1.0), ("nền", 0.65), ("nén", 0.35), ("nến", 0.25)])
        add("neu", [("nếu", 1.0), ("nêu", 0.45)])
        add("thi", [("thì", 1.0), ("thị", 0.65), ("thi", 0.60), ("thí", 0.35)])
        add("ma", [("mà", 1.0), ("mã", 0.65), ("má", 0.45), ("ma", 0.40), ("mạ", 0.20), ("mả", 0.15)])
        add("de", [("để", 1.0), ("dễ", 0.78), ("đề", 0.75), ("đế", 0.35), ("đẻ", 0.25), ("dê", 0.20), ("đê", 0.20), ("dế", 0.15)])
        add("cho", [("cho", 1.0), ("chờ", 0.68), ("chỗ", 0.62), ("chợ", 0.45), ("chó", 0.35), ("chở", 0.30)])
        add("cua", [("của", 1.0), ("cửa", 0.65), ("cưa", 0.25), ("cua", 0.25), ("cựa", 0.10)])
        add("tu", [("từ", 1.0), ("tự", 0.88), ("tư", 0.75), ("tử", 0.45), ("tủ", 0.35), ("tú", 0.30), ("tù", 0.25), ("tu", 0.25)])
        add("den", [("đến", 1.0), ("đen", 0.55), ("đèn", 0.45), ("đền", 0.35)])
        add("trong", [("trong", 1.0), ("trọng", 0.72), ("trống", 0.50), ("trồng", 0.45), ("trông", 0.45)])
        add("ngoai", [("ngoài", 1.0), ("ngoại", 0.65), ("ngoái", 0.25)])
        add("tren", [("trên", 1.0), ("trển", 0.10)])
        add("duoi", [("dưới", 1.0), ("đuôi", 0.40), ("đuổi", 0.40), ("duỗi", 0.15)])
        add("truoc", [("trước", 1.0), ("trược", 0.10)])
        add("sau", [("sau", 1.0), ("sáu", 0.65), ("sâu", 0.62), ("sầu", 0.30), ("sậu", 0.12)])
        add("giua", [("giữa", 1.0), ("giũa", 0.12)])
        add("cung", [("cũng", 1.0), ("cùng", 0.88), ("cung", 0.65), ("cứng", 0.50), ("cúng", 0.25), ("cưng", 0.25)])
        add("nhu", [("như", 1.0), ("nhu", 0.55), ("nhủ", 0.20), ("nhũ", 0.15), ("nhụ", 0.10)])
        add("the", [("thể", 1.0), ("thế", 0.92), ("thẻ", 0.55), ("thề", 0.25), ("thê", 0.20)])
        add("tai", [("tại", 1.0), ("tài", 0.82), ("tải", 0.70), ("tai", 0.50), ("tái", 0.45)])
        add("sao", [("sao", 1.0), ("sáo", 0.25), ("sào", 0.20), ("sảo", 0.12)])
        add("bao", [("bao", 1.0), ("báo", 0.90), ("bảo", 0.85), ("bão", 0.40), ("bạo", 0.35), ("bào", 0.25)])
        add("cac", [("các", 1.0), ("cặc", 0.02)])
        add("mot", [("một", 1.0), ("mọt", 0.12), ("mốt", 0.25)])
        add("hai", [("hai", 1.0), ("hải", 0.50), ("hại", 0.45), ("hài", 0.45), ("hái", 0.25)])
        add("bon", [("bốn", 1.0), ("bọn", 0.60), ("bồn", 0.35), ("bón", 0.25), ("bộn", 0.20)])
        add("nam", [("năm", 1.0), ("nam", 0.75), ("nằm", 0.65), ("nắm", 0.60), ("nấm", 0.25)])
        add("bay", [("bảy", 1.0), ("bay", 0.82), ("bày", 0.65), ("bây", 0.60), ("bấy", 0.35), ("bẫy", 0.30), ("bầy", 0.20)])
        add("tam", [("tám", 1.0), ("tâm", 0.92), ("tạm", 0.85), ("tầm", 0.65), ("tắm", 0.45), ("tấm", 0.45), ("tam", 0.35), ("tăm", 0.20)])
        add("chin", [("chín", 1.0), ("chìn", 0.10)])
        add("muoi", [("mười", 1.0), ("muối", 0.55), ("muỗi", 0.35), ("mươi", 0.50), ("muội", 0.20)])
        add("tram", [("trăm", 1.0), ("trạm", 0.55), ("trầm", 0.45), ("trám", 0.20), ("trâm", 0.20)])
        add("nghin", [("nghìn", 1.0)])
        add("ngan", [("ngàn", 1.0), ("ngắn", 0.88), ("ngăn", 0.65), ("ngân", 0.65), ("ngán", 0.35), ("ngạn", 0.20)])
        add("trieu", [("triệu", 1.0), ("triều", 0.45), ("triêu", 0.15)])
        add("ty", [("tỷ", 1.0), ("ty", 0.90), ("tý", 0.35), ("tỵ", 0.25), ("tỳ", 0.20)])
        add("nhe", [("nhé", 1.0), ("nhẹ", 0.82), ("nhè", 0.20)])
        add("nha", [("nhà", 1.0), ("nha", 0.78), ("nhả", 0.25), ("nhã", 0.25), ("nhá", 0.20)])
        add("a", [("à", 1.0), ("ạ", 0.92), ("á", 0.55), ("a", 0.45), ("ả", 0.15)])
        add("oi", [("ơi", 1.0), ("ối", 0.30), ("ổi", 0.25), ("ôi", 0.35), ("òi", 0.10)])
        add("thoi", [("thôi", 1.0), ("thời", 0.95), ("thói", 0.40), ("thổi", 0.35), ("thối", 0.25), ("thơi", 0.20)])
        add("luon", [("luôn", 1.0), ("luồn", 0.20), ("lươn", 0.25), ("lượn", 0.25)])
        add("cuc", [("cực", 1.0), ("cục", 0.82), ("cúc", 0.40), ("cức", 0.05)])
        add("ky", [("kỳ", 1.0), ("ký", 0.92), ("kỹ", 0.90), ("kỵ", 0.25), ("kỷ", 0.55)])
        add("nua", [("nữa", 1.0), ("nửa", 0.72), ("nứa", 0.15)])
        add("vua", [("vừa", 1.0), ("vua", 0.55), ("vữa", 0.20)])
        add("van", [("vẫn", 1.0), ("vấn", 0.85), ("văn", 0.80), ("vận", 0.65), ("vân", 0.55), ("vạn", 0.45), ("ván", 0.35), ("vặn", 0.25), ("vần", 0.30)])
        add("deu", [("đều", 1.0), ("đểu", 0.15)])
        add("moi", [("mới", 1.0), ("mọi", 0.82), ("mời", 0.58), ("mỗi", 0.58), ("mỏi", 0.35), ("môi", 0.32), ("mối", 0.28)])
        add("ca", [("cả", 1.0), ("cá", 0.72), ("cà", 0.65), ("ca", 0.60)])
        add("het", [("hết", 1.0), ("hét", 0.35), ("hệt", 0.25)])
        add("vay", [("vậy", 1.0), ("vay", 0.55), ("váy", 0.45), ("vẫy", 0.30), ("vây", 0.25), ("vẩy", 0.15)])
        add("hay", [("hay", 1.0), ("hãy", 0.82), ("hây", 0.10)])
        add("tuy", [("tuy", 1.0), ("tùy", 0.88), ("túy", 0.25), ("tụy", 0.20), ("tủy", 0.20)])
        add("du", [("dù", 1.0), ("đủ", 0.95), ("dự", 0.85), ("dữ", 0.72), ("du", 0.55), ("dụ", 0.50), ("đú", 0.15), ("đụ", 0.02)])
        add("bo", [("bộ", 1.0), ("bỏ", 0.90), ("bố", 0.70), ("bò", 0.50), ("bờ", 0.45), ("bơ", 0.40), ("bổ", 0.45), ("bó", 0.35), ("bợ", 0.15), ("bo", 0.25)])
        add("su", [("sự", 1.0), ("sử", 0.82), ("sư", 0.55), ("sứ", 0.45), ("su", 0.25), ("sù", 0.15)])
        add("ve", [("về", 1.0), ("vẽ", 0.55), ("vé", 0.50), ("vẻ", 0.48), ("ve", 0.25), ("vệ", 0.45)])
        add("ra", [("ra", 1.0), ("rã", 0.25), ("rà", 0.25), ("rá", 0.15), ("rạ", 0.10)])
        add("vao", [("vào", 1.0), ("vảo", 0.05)])
        add("len", [("lên", 1.0), ("lén", 0.20), ("len", 0.20)])
        add("xuong", [("xuống", 1.0), ("xưởng", 0.55), ("xương", 0.50), ("xuồng", 0.20)])
        add("lai", [("lại", 1.0), ("lái", 0.55), ("lãi", 0.45), ("lai", 0.35), ("lài", 0.15)])
        add("theo", [("theo", 1.0), ("thẹo", 0.12)])
        add("bang", [("bằng", 1.0), ("bảng", 0.82), ("băng", 0.55), ("bang", 0.45), ("bàng", 0.30), ("báng", 0.20)])
        add("nho", [("nhờ", 1.0), ("nhỏ", 0.95), ("nhớ", 0.92), ("nhỡ", 0.35), ("nho", 0.30), ("nhọ", 0.15), ("nhô", 0.20)])
        add("canh", [("cạnh", 1.0), ("cảnh", 0.92), ("cánh", 0.72), ("canh", 0.65), ("cành", 0.35)])
        add("gan", [("gần", 1.0), ("gắn", 0.75), ("gan", 0.45), ("gán", 0.40), ("gân", 0.30), ("gạn", 0.15)])
        add("xa", [("xa", 1.0), ("xã", 0.82), ("xả", 0.55), ("xá", 0.35), ("xà", 0.30)])

        // --- 2. Time, Calendar & Scheduling ---
        add("khi", [("khi", 1.0), ("khí", 0.65), ("khỉ", 0.25), ("khì", 0.10)])
        add("luc", [("lúc", 1.0), ("lực", 0.82), ("lục", 0.45)])
        add("gio", [("giờ", 1.0), ("gió", 0.55), ("giỏ", 0.35), ("giò", 0.30), ("giở", 0.25), ("giơ", 0.20)])
        add("phut", [("phút", 1.0), ("phụt", 0.15)])
        add("giay", [("giây", 1.0), ("giấy", 0.92), ("giày", 0.65), ("giảy", 0.10)])
        add("hom", [("hôm", 1.0), ("hòm", 0.15), ("hõm", 0.08)])
        add("mai", [("mai", 1.0), ("mãi", 0.75), ("mái", 0.45), ("mài", 0.30), ("mải", 0.25)])
        add("ngay", [("ngày", 1.0), ("ngay", 0.85), ("ngấy", 0.15), ("ngây", 0.20), ("ngáy", 0.15)])
        add("thang", [("tháng", 1.0), ("thẳng", 0.72), ("thắng", 0.68), ("thang", 0.45), ("thằng", 0.45), ("thăng", 0.35)])
        add("tuan", [("tuần", 1.0), ("tuấn", 0.45), ("tuân", 0.35), ("tuẫn", 0.10)])
        add("sang", [("sáng", 1.0), ("sang", 0.85), ("sàng", 0.35), ("sảng", 0.20)])
        add("trua", [("trưa", 1.0)])
        add("chieu", [("chiều", 1.0), ("chiếu", 0.60), ("chiêu", 0.45)])
        add("dem", [("đêm", 1.0), ("đem", 0.78), ("đếm", 0.65), ("đệm", 0.40)])
        add("som", [("sớm", 1.0), ("sồm", 0.08)])
        add("muon", [("muốn", 1.0), ("muộn", 0.65), ("mượn", 0.55), ("muôn", 0.35), ("mướn", 0.20)])
        add("tre", [("trễ", 1.0), ("trẻ", 0.95), ("tre", 0.40)])
        add("xua", [("xưa", 1.0), ("xua", 0.30)])
        add("lau", [("lâu", 1.0), ("lau", 0.55), ("lầu", 0.45), ("lậu", 0.30), ("lẩu", 0.35)])
        add("hien", [("hiện", 1.0), ("hiền", 0.50), ("hiến", 0.35), ("hiển", 0.45), ("hiên", 0.25)])
        add("tuong", [("tương", 1.0), ("tưởng", 0.92), ("tường", 0.72), ("tượng", 0.68), ("tướng", 0.45)])
        add("thu", [("thứ", 1.0), ("thử", 0.88), ("thư", 0.78), ("thu", 0.72), ("thú", 0.62), ("thủ", 0.60), ("thù", 0.30)])
        add("cuoi", [("cuối", 1.0), ("cười", 0.82), ("cưới", 0.55), ("cưỡi", 0.20)])

        // --- 3. Core Actions & Everyday Verbs ---
        add("di", [("đi", 1.0), ("dì", 0.20), ("dị", 0.18), ("di", 0.15), ("dĩ", 0.12)])
        add("lam", [("làm", 1.0), ("lắm", 0.58), ("lâm", 0.28), ("lầm", 0.22), ("lam", 0.15), ("lạm", 0.12)])
        add("an", [("ăn", 1.0), ("an", 0.72), ("án", 0.68), ("ấn", 0.60), ("ẩn", 0.45), ("ân", 0.35), ("ận", 0.10)])
        add("uong", [("uống", 1.0), ("uổng", 0.35)])
        add("ngu", [("ngủ", 1.0), ("ngữ", 0.82), ("ngụ", 0.35), ("ngu", 0.35), ("ngũ", 0.30), ("ngư", 0.20)])
        add("noi", [("nói", 1.0), ("nơi", 0.82), ("nội", 0.78), ("nối", 0.72), ("nổi", 0.68), ("nồi", 0.35), ("nôi", 0.25), ("nới", 0.20)])
        add("viet", [("việt", 1.0), ("viết", 0.85)])
        add("doc", [("đọc", 1.0), ("độc", 0.65), ("dọc", 0.50), ("đốc", 0.35), ("dốc", 0.35)])
        add("xem", [("xem", 1.0), ("xém", 0.12)])
        add("nghe", [("nghe", 1.0), ("nghệ", 0.72), ("nghề", 0.70), ("nghé", 0.18)])
        add("biet", [("biết", 1.0), ("biệt", 0.78), ("biêt", 0.05)])
        add("hieu", [("hiểu", 1.0), ("hiệu", 0.85), ("hiếu", 0.45), ("hiêu", 0.10)])
        add("nghi", [("nghĩ", 1.0), ("nghỉ", 0.78), ("nghị", 0.65), ("nghi", 0.55)])
        add("can", [("cần", 1.0), ("căn", 0.65), ("cân", 0.62), ("cẩn", 0.55), ("cản", 0.45), ("cạn", 0.35), ("cán", 0.35), ("cắn", 0.30), ("cận", 0.30), ("can", 0.25)])
        add("phai", [("phải", 1.0), ("phái", 0.45), ("phai", 0.30)])
        add("thich", [("thích", 1.0)])
        add("yeu", [("yêu", 1.0), ("yếu", 0.72), ("yểu", 0.10)])
        add("quen", [("quên", 1.0), ("quen", 0.88), ("quèn", 0.12)])
        add("gui", [("gửi", 1.0), ("gùi", 0.10)])
        add("nhan", [("nhận", 1.0), ("nhân", 0.88), ("nhấn", 0.72), ("nhắn", 0.68), ("nhẫn", 0.50), ("nhãn", 0.45), ("nhàn", 0.30), ("nhăn", 0.25)])
        add("mo", [("mở", 1.0), ("mô", 0.78), ("mơ", 0.55), ("mờ", 0.45), ("mỡ", 0.35), ("mộ", 0.35), ("mỏ", 0.35), ("mớ", 0.25), ("mo", 0.15)])
        add("dong", [("động", 1.0), ("đóng", 0.90), ("đồng", 0.88), ("đông", 0.75), ("dòng", 0.72), ("đống", 0.40), ("đổng", 0.20), ("đọng", 0.25)])
        add("tao", [("tạo", 1.0), ("táo", 0.55), ("tào", 0.30), ("tao", 0.35), ("tảo", 0.25)])
        add("xoa", [("xóa", 1.0), ("xoa", 0.45), ("xõa", 0.20)])
        add("sua", [("sửa", 1.0), ("sữa", 0.65), ("sủa", 0.20)])
        add("doi", [("đổi", 1.0), ("đối", 0.88), ("đợi", 0.82), ("đời", 0.78), ("đội", 0.72), ("đôi", 0.70), ("đòi", 0.48), ("đói", 0.45), ("dõi", 0.40), ("dối", 0.30)])
        add("luu", [("lưu", 1.0), ("lựu", 0.18)])
        add("chay", [("chạy", 1.0), ("cháy", 0.60), ("chảy", 0.55), ("chay", 0.40), ("chày", 0.20)])
        add("dung", [("dùng", 1.0), ("đúng", 0.96), ("dụng", 0.85), ("dừng", 0.78), ("đứng", 0.72), ("dựng", 0.65), ("dung", 0.55), ("dũng", 0.45), ("đựng", 0.45), ("đụng", 0.35)])
        add("bat", [("bắt", 1.0), ("bật", 0.82), ("bất", 0.78), ("bát", 0.45), ("bạt", 0.25)])
        add("dau", [("đâu", 1.0), ("đầu", 0.88), ("dấu", 0.82), ("đau", 0.58), ("dầu", 0.40), ("đấu", 0.38), ("đậu", 0.32), ("dâu", 0.28)])
        add("ket", [("kết", 1.0), ("kẹt", 0.45), ("két", 0.30)])
        add("thuc", [("thức", 1.0), ("thực", 0.96), ("thúc", 0.78)])
        add("xong", [("xong", 1.0), ("xông", 0.35), ("xổng", 0.15)])
        add("roi", [("rồi", 1.0), ("rơi", 0.62), ("rời", 0.55), ("rối", 0.45), ("rọi", 0.20), ("roi", 0.20)])
        add("chua", [("chưa", 1.0), ("chứa", 0.65), ("chữa", 0.55), ("chùa", 0.45), ("chua", 0.40), ("chúa", 0.35)])
        add("go", [("gõ", 1.0), ("gỡ", 0.62), ("gỗ", 0.55), ("gò", 0.22)])
        add("mua", [("mua", 1.0), ("mùa", 0.75), ("mưa", 0.68), ("múa", 0.28)])
        add("tra", [("tra", 1.0), ("trả", 0.95), ("trà", 0.65), ("trá", 0.15)])
        add("choi", [("chơi", 1.0), ("chối", 0.40), ("chói", 0.30), ("chổi", 0.25), ("chòi", 0.18)])
        add("hoc", [("học", 1.0), ("hộc", 0.15), ("hóc", 0.15)])
        add("giup", [("giúp", 1.0)])
        add("hoi", [("hỏi", 1.0), ("hội", 0.85), ("hơi", 0.78), ("hồi", 0.68), ("hối", 0.35), ("hói", 0.18), ("hôi", 0.20)])
        add("tim", [("tìm", 1.0), ("tim", 0.65), ("tím", 0.45)])
        add("thay", [("thấy", 1.0), ("thay", 0.82), ("thầy", 0.75), ("thảy", 0.20)])
        add("ngoi", [("ngồi", 1.0), ("ngôi", 0.55), ("ngói", 0.25), ("ngời", 0.25)])
        add("lay", [("lấy", 1.0), ("lây", 0.40), ("lầy", 0.25), ("lạy", 0.25), ("lay", 0.25)])
        add("mang", [("mang", 1.0), ("mạng", 0.90), ("mảng", 0.60), ("mắng", 0.35), ("màng", 0.30), ("măng", 0.25)])
        add("dua", [("đưa", 1.0), ("đứa", 0.72), ("dựa", 0.68), ("dưa", 0.35), ("đùa", 0.45), ("đũa", 0.25), ("dứa", 0.25)])
        add("dat", [("đặt", 1.0), ("đạt", 0.85), ("đất", 0.82), ("đắt", 0.55), ("dắt", 0.40), ("dạt", 0.20)])
        add("chon", [("chọn", 1.0), ("chồn", 0.20), ("chôn", 0.30), ("chốn", 0.30), ("chớn", 0.10)])
        add("them", [("thêm", 1.0), ("thèm", 0.45), ("thềm", 0.25)])
        add("bot", [("bớt", 1.0), ("bột", 0.55), ("bọt", 0.35)])
        add("tang", [("tăng", 1.0), ("tặng", 0.82), ("tầng", 0.75), ("tảng", 0.55), ("tạng", 0.35), ("táng", 0.20)])
        add("giam", [("giảm", 1.0), ("giám", 0.75), ("giam", 0.35)])
        add("giu", [("giữ", 1.0), ("giũ", 0.15)])
        add("mat", [("mất", 1.0), ("mặt", 0.90), ("mắt", 0.78), ("mát", 0.65), ("mật", 0.62), ("mạt", 0.15)])
        add("chuyen", [("chuyển", 1.0), ("chuyện", 0.95), ("chuyên", 0.88), ("chuyền", 0.45)])
        add("chia", [("chia", 1.0), ("chìa", 0.35), ("chĩa", 0.15)])
        add("gop", [("góp", 1.0), ("gộp", 0.65)])
        add("gap", [("gặp", 1.0), ("gấp", 0.78), ("gắp", 0.25), ("gập", 0.25)])
        add("chao", [("chào", 1.0), ("cháo", 0.50), ("chảo", 0.35)])
        add("hen", [("hẹn", 1.0), ("hèn", 0.30), ("hen", 0.20)])
        add("xin", [("xin", 1.0), ("xịn", 0.45)])
        add("loi", [("lỗi", 1.0), ("lời", 0.95), ("lợi", 0.82), ("lối", 0.55), ("lôi", 0.45), ("lội", 0.30), ("lõi", 0.30)])
        add("chuc", [("chúc", 1.0), ("chức", 0.88), ("chục", 0.50)])
        add("mung", [("mừng", 1.0), ("mùng", 0.40)])
        add("buon", [("buồn", 1.0), ("buôn", 0.55)])
        add("vui", [("vui", 1.0), ("vùi", 0.25)])
        add("so", [("số", 1.0), ("sợ", 0.78), ("so", 0.75), ("sở", 0.72), ("sơ", 0.55), ("sờ", 0.30), ("sổ", 0.45)])
        add("lo", [("lo", 1.0), ("lỗ", 0.62), ("lộ", 0.60), ("lớ", 0.20), ("lờ", 0.35), ("lỡ", 0.55), ("lò", 0.40), ("lọ", 0.30), ("lô", 0.45)])
        add("cuu", [("cứu", 1.0), ("cựu", 0.45), ("cửu", 0.25)])
        add("kiem", [("kiểm", 1.0), ("kiếm", 0.82), ("kiêm", 0.30), ("kiệm", 0.40)])
        add("xac", [("xác", 1.0)])
        add("duyet", [("duyệt", 1.0)])
        add("nhap", [("nhập", 1.0), ("nhấp", 0.55), ("nháp", 0.45), ("nhắp", 0.15)])
        add("xuat", [("xuất", 1.0)])
        add("in", [("in", 1.0), ("ỉn", 0.05)])
        add("chup", [("chụp", 1.0)])
        add("quay", [("quay", 1.0), ("quậy", 0.35), ("quấy", 0.30), ("quầy", 0.30), ("quày", 0.15)])
        add("phat", [("phát", 1.0), ("phạt", 0.55), ("phật", 0.45)])
        add("trien", [("triển", 1.0)])
        add("xay", [("xây", 1.0), ("xảy", 0.82), ("xay", 0.40), ("xãy", 0.10)])
        add("thiet", [("thiết", 1.0), ("thiệt", 0.55)])
        add("ke", [("kế", 1.0), ("kể", 0.85), ("kẻ", 0.55), ("kệ", 0.50), ("kề", 0.35), ("ke", 0.20)])
        add("lap", [("lập", 1.0), ("lặp", 0.65), ("lắp", 0.60), ("lấp", 0.35)])
        add("trinh", [("trình", 1.0), ("trịnh", 0.25), ("trinh", 0.25)])
        add("chinh", [("chính", 1.0), ("chỉnh", 0.82), ("chình", 0.15)])
        add("cai", [("cái", 1.0), ("cài", 0.85), ("cải", 0.70), ("cãi", 0.40), ("cai", 0.30)])
        add("cap", [("cấp", 1.0), ("cập", 0.82), ("cặp", 0.60), ("cáp", 0.50)])
        add("nang", [("nâng", 1.0), ("năng", 0.95), ("nặng", 0.82), ("nắng", 0.72), ("nàng", 0.40), ("nẵng", 0.35)])
        add("uu", [("ưu", 1.0)])
        add("xu", [("xử", 1.0), ("xu", 0.55), ("xứ", 0.45), ("xù", 0.25), ("xú", 0.15)])
        add("ly", [("lý", 1.0), ("ly", 0.55), ("lỳ", 0.15)])
        add("phan", [("phần", 1.0), ("phân", 0.88), ("phản", 0.75), ("phận", 0.50), ("phấn", 0.45), ("phan", 0.30), ("phán", 0.30)])
        add("tich", [("tích", 1.0), ("tịch", 0.45)])
        add("tong", [("tổng", 1.0), ("tông", 0.40), ("tống", 0.30), ("tòng", 0.20)])
        add("hop", [("họp", 1.0), ("hợp", 0.96), ("hộp", 0.65)])
        add("soan", [("soạn", 1.0)])
        add("dich", [("dịch", 1.0), ("đích", 0.82), ("địch", 0.45)])
        add("dien", [("điện", 1.0), ("diễn", 0.82), ("diện", 0.75), ("điển", 0.70), ("điền", 0.55), ("điên", 0.45)])
        add("giai", [("giải", 1.0), ("giai", 0.65), ("giãi", 0.15)])
        add("quyet", [("quyết", 1.0), ("quyệt", 0.10)])
        add("nghiem", [("nghiệm", 1.0), ("nghiêm", 0.75)])
        add("danh", [("đánh", 1.0), ("dành", 0.88), ("danh", 0.78), ("đành", 0.45)])
        add("gia", [("giá", 1.0), ("gia", 0.88), ("già", 0.65), ("giả", 0.65), ("giã", 0.25)])
        add("y", [("ý", 1.0), ("y", 0.65), ("ỷ", 0.15)])
        add("chap", [("chấp", 1.0), ("chập", 0.25), ("chắp", 0.20)])
        add("hoan", [("hoàn", 1.0), ("hoãn", 0.55), ("hoán", 0.30), ("hoan", 0.30)])
        add("thanh", [("thành", 1.0), ("thanh", 0.78), ("thánh", 0.40), ("thảnh", 0.20)])
        add("tiep", [("tiếp", 1.0), ("tiệp", 0.15)])
        add("tuc", [("tục", 1.0), ("tức", 0.82), ("túc", 0.40)])
        add("ngung", [("ngừng", 1.0), ("ngưng", 0.75)])
        add("huy", [("hủy", 1.0), ("huy", 0.65), ("húy", 0.15)])
        add("khoi", [("khởi", 1.0), ("khỏi", 0.92), ("khối", 0.78), ("khói", 0.45), ("khôi", 0.45)])
        add("tat", [("tất", 1.0), ("tắt", 0.88), ("tát", 0.30), ("tật", 0.35), ("tạt", 0.20)])
        add("khoa", [("khóa", 1.0), ("khoa", 0.85), ("khỏa", 0.20)])
        add("bam", [("bấm", 1.0), ("bám", 0.65), ("bầm", 0.30), ("băm", 0.30), ("bậm", 0.10)])
        add("keo", [("kéo", 1.0), ("kẹo", 0.55), ("keo", 0.45), ("kèo", 0.45)])
        add("tha", [("thả", 1.0), ("tha", 0.65), ("thà", 0.45)])
        add("truot", [("trượt", 1.0)])
        add("cuon", [("cuộn", 1.0), ("cuốn", 0.92)])
        add("dan", [("dẫn", 1.0), ("dân", 0.90), ("dần", 0.78), ("dán", 0.65), ("đàn", 0.60), ("đạn", 0.45), ("đan", 0.35), ("dặn", 0.45), ("đặn", 0.30), ("đần", 0.15)])
        add("chep", [("chép", 1.0)])
        add("cat", [("cắt", 1.0), ("cát", 0.55), ("cất", 0.55)])
        add("phuc", [("phục", 1.0), ("phúc", 0.78), ("phức", 0.70)])

        // --- 4. Adjectives & Adverbs ---
        add("cu", [("cũ", 1.0), ("cụ", 0.85), ("cứ", 0.82), ("cử", 0.55), ("cư", 0.50), ("củ", 0.40), ("cú", 0.40), ("cu", 0.25)])
        add("tot", [("tốt", 1.0), ("tột", 0.20)])
        add("xau", [("xấu", 1.0), ("xâu", 0.35)])
        add("dep", [("đẹp", 1.0), ("dép", 0.40), ("dẹp", 0.35)])
        add("nhanh", [("nhanh", 1.0), ("nhánh", 0.55), ("nhành", 0.25)])
        add("cham", [("chậm", 1.0), ("chăm", 0.78), ("chấm", 0.75), ("chạm", 0.68), ("châm", 0.45), ("chầm", 0.25)])
        add("kho", [("khó", 1.0), ("kho", 0.75), ("khô", 0.65), ("khổ", 0.60), ("khờ", 0.20)])
        add("lon", [("lớn", 1.0), ("lộn", 0.55), ("lợn", 0.40), ("lơn", 0.15)])
        add("be", [("bé", 1.0), ("bè", 0.45), ("bể", 0.50), ("bề", 0.50), ("bệ", 0.30), ("bê", 0.35), ("bẻ", 0.30)])
        add("to", [("to", 1.0), ("tổ", 0.88), ("tờ", 0.72), ("tô", 0.65), ("tớ", 0.60), ("tỏ", 0.55), ("tố", 0.55), ("tơ", 0.35), ("tộ", 0.15)])
        add("cao", [("cao", 1.0), ("cáo", 0.75), ("cào", 0.30), ("cạo", 0.25), ("cảo", 0.15)])
        add("thap", [("thấp", 1.0), ("tháp", 0.50), ("thập", 0.45), ("thắp", 0.30)])
        add("dai", [("dài", 1.0), ("đại", 0.90), ("đài", 0.60), ("dải", 0.45), ("dại", 0.40), ("đãi", 0.35), ("đai", 0.30), ("dai", 0.25), ("dãi", 0.15)])
        add("rong", [("rộng", 1.0), ("rồng", 0.45), ("rỗng", 0.45), ("rong", 0.30)])
        add("hep", [("hẹp", 1.0)])
        add("manh", [("mạnh", 1.0), ("mảnh", 0.60), ("mãnh", 0.35), ("manh", 0.25), ("mành", 0.20)])
        add("sai", [("sai", 1.0), ("sài", 0.45), ("sải", 0.20), ("sãi", 0.10)])
        add("that", [("thật", 1.0), ("thất", 0.72), ("thắt", 0.40)])
        add("binh", [("bình", 1.0), ("binh", 0.50), ("bính", 0.25), ("bịnh", 0.15)])
        add("thuong", [("thường", 1.0), ("thương", 0.85), ("thưởng", 0.72), ("thượng", 0.50)])
        add("dac", [("đặc", 1.0), ("đắc", 0.45)])
        add("ro", [("rõ", 1.0), ("rổ", 0.35), ("rò", 0.30), ("rơ", 0.20), ("rộ", 0.25)])
        add("rang", [("ràng", 1.0), ("rằng", 0.92), ("răng", 0.65), ("rang", 0.40), ("rạng", 0.30), ("ráng", 0.35)])
        add("sanh", [("sành", 1.0), ("sảnh", 0.55), ("sánh", 0.60), ("sanh", 0.30)])
        add("sach", [("sạch", 1.0), ("sách", 0.95)])
        add("gon", [("gọn", 1.0), ("gòn", 0.45)])
        add("tien", [("tiện", 1.0), ("tiền", 0.96), ("tiến", 0.88), ("tiên", 0.85), ("tiễn", 0.25)])
        add("thong", [("thông", 1.0), ("thống", 0.88), ("thòng", 0.15), ("thổng", 0.10)])
        add("dinh", [("định", 1.0), ("đỉnh", 0.72), ("đình", 0.68), ("dính", 0.50), ("đinh", 0.45), ("dinh", 0.40)])
        add("toan", [("toàn", 1.0), ("toán", 0.85), ("toan", 0.30), ("toản", 0.15)])
        add("rieng", [("riêng", 1.0), ("riềng", 0.20)])
        add("cong", [("công", 1.0), ("cộng", 0.85), ("cổng", 0.65), ("cống", 0.40), ("cong", 0.40), ("còng", 0.25), ("cõng", 0.25)])
        add("khai", [("khai", 1.0), ("khải", 0.25), ("khái", 0.55)])
        add("muot", [("mượt", 1.0), ("mướt", 0.35)])
        add("nong", [("nóng", 1.0), ("nông", 0.78), ("nồng", 0.45), ("nòng", 0.25), ("nọng", 0.15)])
        add("lanh", [("lạnh", 1.0), ("lành", 0.78), ("lãnh", 0.72), ("lanh", 0.35), ("lánh", 0.25)])
        add("am", [("ấm", 1.0), ("âm", 0.90), ("ẩm", 0.60), ("ầm", 0.40), ("ám", 0.35), ("ạm", 0.10)])
        add("ngon", [("ngon", 1.0), ("ngôn", 0.82), ("ngọn", 0.60), ("ngón", 0.55), ("ngốn", 0.20)])
        add("ngot", [("ngọt", 1.0), ("ngột", 0.35)])
        add("cay", [("cây", 1.0), ("cay", 0.72), ("cày", 0.45), ("cấy", 0.40), ("cậy", 0.30)])
        add("man", [("mặn", 1.0), ("màn", 0.92), ("mắn", 0.65), ("mãn", 0.45), ("mận", 0.40), ("mẫn", 0.35), ("man", 0.30), ("mạn", 0.25)])
        add("met", [("mệt", 1.0), ("mét", 0.65)])
        add("khoe", [("khỏe", 1.0), ("khoe", 0.55)])
        add("benh", [("bệnh", 1.0), ("bênh", 0.35)])
        add("ranh", [("rảnh", 1.0), ("ranh", 0.50), ("rành", 0.45), ("rãnh", 0.30)])
        add("giong", [("giống", 1.0), ("giọng", 0.78), ("giòng", 0.15)])
        add("khac", [("khác", 1.0), ("khắc", 0.65), ("khạc", 0.10)])
        add("duy", [("duy", 1.0)])
        add("chac", [("chắc", 1.0), ("chặc", 0.15), ("chác", 0.12)])
        add("chan", [("chắn", 1.0), ("chân", 0.92), ("chán", 0.68), ("chăn", 0.50), ("chặn", 0.65), ("chẩn", 0.45), ("chần", 0.25)])
        add("ngau", [("ngẫu", 1.0), ("ngầu", 0.65), ("ngấu", 0.20)])
        add("nhien", [("nhiên", 1.0)])
        add("than", [("thân", 1.0), ("thần", 0.85), ("thận", 0.75), ("than", 0.55), ("thán", 0.35), ("thản", 0.30)])
        add("quan", [("quan", 1.0), ("quản", 0.92), ("quận", 0.75), ("quán", 0.72), ("quân", 0.70), ("quần", 0.65), ("quấn", 0.35), ("quẩn", 0.20)])
        add("tuyet", [("tuyệt", 1.0), ("tuyết", 0.55)])
        add("sac", [("sắc", 1.0), ("sạc", 0.65), ("sác", 0.20)])
        add("hao", [("hảo", 1.0), ("hao", 0.55), ("hào", 0.60), ("háo", 0.35)])

        // --- 5. People, Life, Work, Business & Tech Nouns ---
        add("nguoi", [("người", 1.0), ("nguội", 0.25), ("ngươi", 0.20)])
        add("viec", [("việc", 1.0)])
        add("cach", [("cách", 1.0), ("cạch", 0.12)])
        add("may", [("máy", 1.0), ("mấy", 0.85), ("may", 0.72), ("mây", 0.55), ("mày", 0.45)])
        add("tinh", [("tính", 1.0), ("tình", 0.92), ("tỉnh", 0.75), ("tinh", 0.65), ("tĩnh", 0.45)])
        add("thoai", [("thoại", 1.0), ("thoải", 0.75), ("thoái", 0.30)])
        add("mem", [("mềm", 1.0)])
        add("ung", [("ứng", 1.0), ("ủng", 0.55), ("ung", 0.40), ("ưng", 0.45), ("ửng", 0.15)])
        add("tieng", [("tiếng", 1.0)])
        add("cau", [("câu", 1.0), ("cầu", 0.90), ("cấu", 0.85), ("cậu", 0.65), ("cau", 0.25), ("cáu", 0.30), ("cẩu", 0.25)])
        add("khau", [("khẩu", 1.0), ("khâu", 0.65), ("khấu", 0.40)])
        add("tap", [("tập", 1.0), ("tạp", 0.45), ("tấp", 0.25), ("táp", 0.20)])
        add("nhom", [("nhóm", 1.0), ("nhôm", 0.40), ("nhồm", 0.10)])
        add("hoach", [("hoạch", 1.0)])
        add("muc", [("mục", 1.0), ("mức", 0.92), ("mực", 0.50)])
        add("tieu", [("tiêu", 1.0), ("tiểu", 0.72), ("tiếu", 0.20)])
        add("buoc", [("bước", 1.0), ("buộc", 0.75)])
        add("truong", [("trường", 1.0), ("trưởng", 0.82), ("trương", 0.45), ("trướng", 0.20)])
        add("kha", [("khả", 1.0), ("khá", 0.95), ("kha", 0.25)])
        add("nhac", [("nhắc", 1.0), ("nhạc", 0.88), ("nhấc", 0.45), ("nhác", 0.20)])
        add("huong", [("hướng", 1.0), ("hưởng", 0.78), ("hương", 0.72), ("huống", 0.55)])
        add("he", [("hệ", 1.0), ("hè", 0.65), ("hé", 0.35), ("hề", 0.30)])
        add("hinh", [("hình", 1.0), ("hĩnh", 0.10)])
        add("lieu", [("liệu", 1.0), ("liều", 0.45), ("liễu", 0.25)])
        add("phim", [("phím", 1.0), ("phim", 0.92)])
        add("chuot", [("chuột", 1.0)])
        add("nut", [("nút", 1.0), ("nứt", 0.35), ("nụt", 0.10)])
        add("tep", [("tệp", 1.0), ("tép", 0.30)])
        add("trang", [("trang", 1.0), ("trạng", 0.85), ("trắng", 0.72), ("trăng", 0.50), ("tràng", 0.30), ("tráng", 0.30)])
        add("thai", [("thái", 1.0), ("thai", 0.65), ("thải", 0.55)])
        add("khoan", [("khoản", 1.0), ("khoan", 0.55), ("khoán", 0.40)])
        add("khoang", [("khoảng", 1.0), ("khoang", 0.45), ("khoáng", 0.45)])
        add("quyen", [("quyền", 1.0), ("quyển", 0.55), ("quyến", 0.35), ("quyện", 0.20)])
        add("truy", [("truy", 1.0)])
        add("tin", [("tin", 1.0), ("tín", 0.72)])
        add("bai", [("bài", 1.0), ("bãi", 0.55), ("bại", 0.45), ("bái", 0.25)])
        add("doan", [("đoạn", 1.0), ("đoàn", 0.82), ("đoán", 0.75), ("đoan", 0.25)])
        add("cot", [("cột", 1.0), ("cốt", 0.65), ("cọt", 0.10)])
        add("hang", [("hàng", 1.0), ("hạng", 0.72), ("hãng", 0.68), ("hằng", 0.55), ("hang", 0.40), ("hăng", 0.35)])
        add("bieu", [("biểu", 1.0), ("biếu", 0.30)])
        add("luong", [("lượng", 1.0), ("lương", 0.85), ("luồng", 0.65), ("lường", 0.40), ("luống", 0.20)])
        add("chat", [("chất", 1.0), ("chặt", 0.65), ("chát", 0.35), ("chật", 0.40)])
        add("tri", [("trị", 1.0), ("trí", 0.92), ("trì", 0.65), ("tri", 0.55)])
        add("phi", [("phí", 1.0), ("phi", 0.65), ("phì", 0.20)])
        add("khach", [("khách", 1.0)])
        add("tac", [("tác", 1.0), ("tắc", 0.55), ("tạc", 0.20)])
        add("doanh", [("doanh", 1.0)])
        add("nghiep", [("nghiệp", 1.0)])
        add("san", [("sản", 1.0), ("sẵn", 0.88), ("sân", 0.78), ("sàn", 0.68), ("săn", 0.45), ("san", 0.35), ("sạn", 0.20)])
        add("pham", [("phẩm", 1.0), ("phạm", 0.78), ("phàm", 0.20)])
        add("vu", [("vụ", 1.0), ("vũ", 0.65), ("vú", 0.25), ("vù", 0.20), ("vu", 0.20)])
        add("chien", [("chiến", 1.0), ("chiên", 0.45)])
        add("luoc", [("lược", 1.0), ("luộc", 0.45)])
        add("quy", [("quy", 1.0), ("quý", 0.88), ("quỹ", 0.72), ("quỷ", 0.35), ("quỳ", 0.30)])
        add("chuan", [("chuẩn", 1.0)])
        add("suat", [("suất", 1.0)])
        add("toc", [("tốc", 1.0), ("tóc", 0.82), ("tộc", 0.55)])
        add("kinh", [("kinh", 1.0), ("kính", 0.82), ("kỉnh", 0.10)])
        add("kien", [("kiến", 1.0), ("kiện", 0.90), ("kiên", 0.65), ("kiển", 0.15)])
        add("phap", [("pháp", 1.0)])
        add("phuong", [("phương", 1.0), ("phường", 0.65), ("phượng", 0.40)])
        add("che", [("chế", 1.0), ("che", 0.65), ("chè", 0.55), ("chê", 0.45), ("chẻ", 0.25)])
        add("nguyen", [("nguyên", 1.0), ("nguyện", 0.65), ("nguyễn", 0.72), ("nguyền", 0.20)])
        add("luat", [("luật", 1.0)])
        add("dieu", [("điều", 1.0), ("điệu", 0.55), ("điêu", 0.30), ("diều", 0.30), ("diệu", 0.35)])
        add("trach", [("trách", 1.0), ("trạch", 0.25)])
        add("nhiem", [("nhiệm", 1.0), ("nhiễm", 0.55)])
        add("vai", [("vai", 1.0), ("vài", 0.95), ("vải", 0.55), ("vái", 0.20)])
        add("tro", [("trò", 1.0), ("trợ", 0.92), ("trở", 0.90), ("trọ", 0.55), ("tro", 0.30), ("trỏ", 0.40), ("trơ", 0.25)])
        add("phong", [("phòng", 1.0), ("phong", 0.82), ("phóng", 0.68), ("phỏng", 0.45), ("phồng", 0.25)])
        add("vien", [("viên", 1.0), ("viện", 0.85), ("viễn", 0.45), ("viền", 0.35)])
        add("sep", [("sếp", 1.0)])
        add("dao", [("đạo", 1.0), ("đào", 0.75), ("đảo", 0.70), ("dao", 0.60), ("dạo", 0.55), ("đáo", 0.40)])

        // --- 6. Places, Nature, Food, Body, Everyday Objects ---
        add("troi", [("trời", 1.0), ("trôi", 0.55), ("trội", 0.45), ("trọi", 0.15)])
        add("nuoc", [("nước", 1.0)])
        add("lua", [("lửa", 1.0), ("lựa", 0.82), ("lúa", 0.55), ("lụa", 0.45), ("lùa", 0.25)])
        add("bien", [("biển", 1.0), ("biến", 0.92), ("biên", 0.72), ("biện", 0.65)])
        add("song", [("sống", 1.0), ("sông", 0.85), ("sóng", 0.75), ("song", 0.65), ("sộng", 0.10)])
        add("nui", [("núi", 1.0), ("nùi", 0.10)])
        add("rung", [("rừng", 1.0), ("rung", 0.55), ("rụng", 0.50), ("rùng", 0.30)])
        add("hoa", [("hòa", 1.0), ("hóa", 0.95), ("hoa", 0.92), ("họa", 0.50)])
        add("trai", [("trái", 1.0), ("trải", 0.85), ("trai", 0.80), ("trại", 0.50)])
        add("pho", [("phố", 1.0), ("phổ", 0.75), ("phở", 0.65), ("phó", 0.60), ("phô", 0.30)])
        add("duong", [("đường", 1.0), ("dương", 0.78), ("dưỡng", 0.65), ("đương", 0.55), ("dường", 0.40)])
        add("tiem", [("tiệm", 1.0), ("tiêm", 0.65), ("tiềm", 0.65)])
        add("sieu", [("siêu", 1.0)])
        add("lop", [("lớp", 1.0), ("lốp", 0.45)])
        add("xe", [("xe", 1.0), ("xé", 0.35), ("xẻ", 0.30)])
        add("tau", [("tàu", 1.0), ("tầu", 0.25), ("táu", 0.15)])
        add("com", [("cơm", 1.0), ("cốm", 0.35), ("cộm", 0.20)])
        add("bun", [("bún", 1.0), ("bùn", 0.45), ("bủn", 0.15)])
        add("banh", [("bánh", 1.0), ("banh", 0.45), ("bành", 0.25), ("bảnh", 0.25)])
        add("mi", [("mì", 1.0), ("mi", 0.45), ("mí", 0.35), ("mĩ", 0.25), ("mị", 0.20)])
        add("thit", [("thịt", 1.0), ("thít", 0.15)])
        add("rau", [("rau", 1.0), ("râu", 0.50), ("rầu", 0.25), ("ráu", 0.15)])
        add("trung", [("trung", 1.0), ("trúng", 0.82), ("trứng", 0.75), ("trùng", 0.65), ("trưng", 0.45)])
        add("phe", [("phê", 1.0), ("phe", 0.60), ("phế", 0.40)])
        add("bia", [("bia", 1.0), ("bìa", 0.55), ("bịa", 0.35)])
        add("ruou", [("rượu", 1.0)])
        add("ao", [("áo", 1.0), ("ảo", 0.78), ("ao", 0.55), ("ào", 0.35)])
        add("mu", [("mũ", 1.0), ("mù", 0.55), ("mụ", 0.30), ("mu", 0.25), ("mủ", 0.25)])
        add("tui", [("túi", 1.0), ("tủi", 0.25), ("tui", 0.45)])
        add("ghe", [("ghế", 1.0), ("ghé", 0.65), ("ghẻ", 0.15)])
        add("giuong", [("giường", 1.0)])
        add("quat", [("quạt", 1.0), ("quát", 0.35)])
        add("vo", [("vợ", 1.0), ("vở", 0.72), ("vô", 0.85), ("vỡ", 0.65), ("vỏ", 0.55), ("vỗ", 0.40), ("vớ", 0.35), ("võ", 0.45), ("vờ", 0.30), ("vo", 0.25)])
        add("but", [("bút", 1.0), ("bụt", 0.20)])
        add("tay", [("tay", 1.0), ("tây", 0.78), ("tẩy", 0.45), ("tấy", 0.20)])
        add("mui", [("mũi", 1.0), ("mùi", 0.88), ("múi", 0.35), ("mụi", 0.15)])
        add("mieng", [("miệng", 1.0), ("miếng", 0.85)])
        add("mau", [("màu", 1.0), ("mẫu", 0.90), ("máu", 0.78), ("mau", 0.45), ("mậu", 0.25)])
        add("me", [("mẹ", 1.0), ("mê", 0.65), ("me", 0.35), ("mẻ", 0.30), ("mè", 0.25)])
        add("chong", [("chồng", 1.0), ("chống", 0.88), ("chóng", 0.60), ("chổng", 0.20), ("chỏng", 0.15)])
        add("sinh", [("sinh", 1.0), ("sính", 0.15)])
        add("chet", [("chết", 1.0)])

        // --- 7. Additional High-Frequency Syllables for Broad Coverage (250+ more) ---
        add("bi", [("bị", 1.0), ("bí", 0.70), ("bi", 0.55), ("bì", 0.35), ("bỉ", 0.25)])
        add("boc", [("bóc", 1.0), ("bọc", 0.88), ("bốc", 0.75), ("bộc", 0.55)])
        add("boi", [("bởi", 1.0), ("bơi", 0.72), ("bối", 0.60), ("bói", 0.35), ("bồi", 0.45), ("bôi", 0.40)])
        add("bong", [("bóng", 1.0), ("bông", 0.72), ("bỗng", 0.65), ("bỏng", 0.40), ("bồng", 0.35), ("bọng", 0.20)])
        add("bua", [("bữa", 1.0), ("bừa", 0.55), ("búa", 0.45), ("bùa", 0.35)])
        add("buc", [("bức", 1.0), ("bực", 0.65), ("bục", 0.35)])
        add("bung", [("bụng", 1.0), ("bùng", 0.65), ("bưng", 0.40), ("bừng", 0.40), ("bung", 0.40), ("bứng", 0.20)])
        add("buoi", [("buổi", 1.0), ("bưởi", 0.50)])
        add("cang", [("càng", 1.0), ("căng", 0.82), ("cảng", 0.65), ("cẳng", 0.25)])
        add("chang", [("chẳng", 1.0), ("chàng", 0.60), ("chặng", 0.50), ("chăng", 0.45), ("chằng", 0.25)])
        add("chiec", [("chiếc", 1.0)])
        add("chiem", [("chiếm", 1.0), ("chiêm", 0.45)])
        add("chiu", [("chịu", 1.0), ("chíu", 0.15)])
        add("choc", [("chốc", 1.0), ("chọc", 0.75), ("chóc", 0.35)])
        add("chot", [("chốt", 1.0), ("chợt", 0.72), ("chót", 0.50)])
        add("chui", [("chui", 1.0), ("chửi", 0.75), ("chùi", 0.40), ("chúi", 0.20)])
        add("chuoi", [("chuỗi", 1.0), ("chuối", 0.72)])
        add("chuong", [("chương", 1.0), ("chuông", 0.65), ("chuộng", 0.45), ("chuồng", 0.35)])
        add("chut", [("chút", 1.0), ("chụt", 0.10)])
        add("coi", [("coi", 1.0), ("cõi", 0.45), ("còi", 0.45), ("cởi", 0.65), ("cơi", 0.20), ("cội", 0.35)])
        add("cuoc", [("cuộc", 1.0), ("cước", 0.68), ("cuốc", 0.40)])
        add("cuong", [("cường", 1.0), ("cưỡng", 0.55), ("cương", 0.50)])
        add("cuop", [("cướp", 1.0)])
        add("dam", [("đảm", 1.0), ("đám", 0.85), ("đậm", 0.75), ("đầm", 0.65), ("dám", 0.80), ("đâm", 0.60), ("dầm", 0.30), ("đàm", 0.45)])
        add("dap", [("đáp", 1.0), ("đập", 0.82), ("đạp", 0.65), ("đắp", 0.50)])
        add("deo", [("đeo", 1.0), ("đèo", 0.50), ("dẻo", 0.55), ("đẽo", 0.20)])
        add("dia", [("địa", 1.0), ("đĩa", 0.65), ("dĩa", 0.40), ("đỉa", 0.15)])
        add("diem", [("điểm", 1.0), ("diễm", 0.30)])
        add("diep", [("điệp", 1.0), ("diệp", 0.45)])
        add("diet", [("diệt", 1.0)])
        add("dip", [("dịp", 1.0)])
        add("don", [("đơn", 1.0), ("đón", 0.85), ("dọn", 0.78), ("đồn", 0.55), ("dồn", 0.55), ("độn", 0.30), ("đốn", 0.25)])
        add("dot", [("đợt", 1.0), ("đốt", 0.75), ("đột", 0.72), ("dốt", 0.35), ("dột", 0.25)])
        add("duc", [("đức", 1.0), ("đục", 0.55), ("đúc", 0.55), ("dục", 0.60)])
        add("dut", [("đứt", 1.0), ("dứt", 0.78), ("đút", 0.35)])
        add("duyen", [("duyên", 1.0)])
        add("ep", [("ép", 1.0)])
        add("ga", [("gà", 1.0), ("ga", 0.75), ("gã", 0.35), ("gả", 0.25), ("gá", 0.20)])
        add("gac", [("gác", 1.0), ("gạc", 0.30)])
        add("gai", [("gái", 1.0), ("gai", 0.55), ("gài", 0.50), ("gãi", 0.30)])
        add("gang", [("gắng", 1.0), ("găng", 0.50), ("gang", 0.40), ("gàng", 0.20)])
        add("ganh", [("gánh", 1.0), ("ganh", 0.45), ("gành", 0.20)])
        add("gao", [("gạo", 1.0), ("gào", 0.35), ("gáo", 0.25)])
        add("gat", [("gạt", 1.0), ("gắt", 0.65), ("gật", 0.60), ("gặt", 0.45)])
        add("gay", [("gây", 1.0), ("gãy", 0.65), ("gầy", 0.60), ("gậy", 0.45), ("gáy", 0.35)])
        add("ghep", [("ghép", 1.0)])
        add("ghet", [("ghét", 1.0)])
        add("ghi", [("ghi", 1.0), ("ghì", 0.20)])
        add("giau", [("giàu", 1.0), ("giấu", 0.78)])
        add("giao", [("giao", 1.0), ("giáo", 0.90), ("giảo", 0.15)])
        add("giac", [("giác", 1.0), ("giấc", 0.88), ("giặc", 0.40)])
        add("gian", [("gian", 1.0), ("giản", 0.88), ("giận", 0.72), ("giãn", 0.55), ("gián", 0.45), ("giàn", 0.35)])
        add("giang", [("giảng", 1.0), ("giang", 0.70), ("giáng", 0.55), ("giăng", 0.30)])
        add("gianh", [("giành", 1.0)])
        add("giap", [("giáp", 1.0)])
        add("giat", [("giặt", 1.0), ("giật", 0.92), ("giắt", 0.20)])
        add("gieng", [("giếng", 1.0), ("giêng", 0.65)])
        add("giet", [("giết", 1.0)])
        add("gioi", [("giới", 1.0), ("giỏi", 0.90), ("giời", 0.25)])
        add("giot", [("giọt", 1.0)])
        add("goc", [("góc", 1.0), ("gốc", 0.92)])
        add("goi", [("gọi", 1.0), ("gói", 0.82), ("gợi", 0.78), ("gối", 0.55), ("gội", 0.45)])
        add("gom", [("gồm", 1.0), ("gom", 0.72), ("gốm", 0.45)])
        add("guong", [("gương", 1.0), ("gượng", 0.40)])
        add("ha", [("hà", 1.0), ("hạ", 0.88), ("hả", 0.50), ("há", 0.30), ("ha", 0.45)])
        add("ham", [("hàm", 1.0), ("hầm", 0.72), ("ham", 0.65), ("hăm", 0.35), ("hạm", 0.25)])
        add("han", [("hạn", 1.0), ("hàn", 0.75), ("hắn", 0.60), ("hân", 0.55), ("hận", 0.45), ("hãn", 0.25)])
        add("hanh", [("hành", 1.0), ("hạnh", 0.82), ("hanh", 0.35)])
        add("hap", [("hấp", 1.0), ("hạp", 0.15)])
        add("hat", [("hát", 1.0), ("hạt", 0.78), ("hất", 0.35)])
        add("hau", [("hầu", 1.0), ("hậu", 0.88), ("háu", 0.20)])
        add("hem", [("hẻm", 1.0)])
        add("hiep", [("hiệp", 1.0), ("hiếp", 0.20)])
        add("hiem", [("hiếm", 1.0), ("hiểm", 0.88)])
        add("hoang", [("hoàng", 1.0), ("hoang", 0.70), ("hoảng", 0.60), ("hoằng", 0.15)])
        add("hoat", [("hoạt", 1.0)])
        add("hong", [("hỏng", 1.0), ("hồng", 0.92), ("hóng", 0.65), ("họng", 0.55), ("hông", 0.50)])
        add("hua", [("hứa", 1.0)])
        add("hung", [("hứng", 1.0), ("hùng", 0.85), ("hưng", 0.72), ("hung", 0.45), ("hững", 0.25)])
        add("hut", [("hút", 1.0), ("hụt", 0.55)])
        add("huyen", [("huyện", 1.0), ("huyền", 0.82), ("huyên", 0.30)])
        add("huu", [("hữu", 1.0), ("hưu", 0.65)])
        add("im", [("im", 1.0)])
        add("kem", [("kèm", 1.0), ("kém", 0.92), ("kem", 0.72), ("kẽm", 0.35)])
        add("ken", [("kén", 1.0), ("kèn", 0.65), ("kền", 0.25)])
        add("kenh", [("kênh", 1.0), ("kệnh", 0.10)])
        add("kep", [("kẹp", 1.0), ("kép", 0.72)])
        add("kham", [("khám", 1.0), ("khảm", 0.25), ("khấm", 0.25)])
        add("khan", [("khăn", 1.0), ("khẩn", 0.85), ("khán", 0.72), ("khàn", 0.35), ("khan", 0.35)])
        add("khang", [("kháng", 1.0), ("khẳng", 0.92), ("khang", 0.55)])
        add("khanh", [("khánh", 1.0), ("khanh", 0.35)])
        add("khap", [("khắp", 1.0)])
        add("khao", [("khảo", 1.0), ("kháo", 0.25), ("khao", 0.40)])
        add("khat", [("khát", 1.0), ("khắt", 0.55)])
        add("khen", [("khen", 1.0)])
        add("kheo", [("khéo", 1.0)])
        add("khep", [("khép", 1.0)])
        add("khia", [("khía", 1.0)])
        add("khich", [("khích", 1.0)])
        add("khien", [("khiến", 1.0), ("khiển", 0.88), ("khiên", 0.35)])
        add("khoc", [("khóc", 1.0)])
        add("khu", [("khu", 1.0), ("khử", 0.72), ("khứ", 0.65)])
        add("khuc", [("khúc", 1.0)])
        add("khung", [("khung", 1.0), ("khủng", 0.85), ("khùng", 0.45)])
        add("khuon", [("khuôn", 1.0)])
        add("khuya", [("khuya", 1.0)])
        add("khuyen", [("khuyên", 1.0), ("khuyến", 0.90)])
        add("khuyet", [("khuyết", 1.0)])
        add("kich", [("kích", 1.0), ("kịch", 0.85)])
        add("kieu", [("kiểu", 1.0), ("kiều", 0.55), ("kiêu", 0.45)])
        add("kim", [("kim", 1.0), ("kìm", 0.55)])
        add("kin", [("kín", 1.0)])
        add("kip", [("kịp", 1.0)])
        add("lan", [("lần", 1.0), ("lan", 0.65), ("lẫn", 0.72), ("lấn", 0.55), ("lân", 0.50), ("lăn", 0.50), ("lặn", 0.45), ("làn", 0.40), ("lạn", 0.15)])
        add("lang", [("làng", 1.0), ("lắng", 0.88), ("lặng", 0.85), ("lãng", 0.70), ("lăng", 0.55), ("lạng", 0.30)])
        add("lao", [("lao", 1.0), ("lão", 0.72), ("láo", 0.35), ("lào", 0.35)])
        add("lat", [("lát", 1.0), ("lật", 0.82), ("lạt", 0.35), ("lắt", 0.25)])
        add("le", [("lẽ", 1.0), ("lễ", 0.95), ("lẻ", 0.80), ("lệ", 0.85), ("lề", 0.55), ("lẹ", 0.50), ("le", 0.20)])
        add("lech", [("lệch", 1.0)])
        add("lenh", [("lệnh", 1.0), ("lênh", 0.35)])
        add("leo", [("leo", 1.0), ("lẻo", 0.45), ("lèo", 0.35), ("léo", 0.20)])
        add("liem", [("liêm", 1.0), ("liếm", 0.30)])
        add("lien", [("liên", 1.0), ("liền", 0.88)])
        add("liet", [("liệt", 1.0)])
        add("lich", [("lịch", 1.0)])
        add("linh", [("lĩnh", 1.0), ("linh", 0.92), ("lính", 0.75)])
        add("loai", [("loại", 1.0), ("loài", 0.65)])
        add("loan", [("loạn", 1.0), ("loan", 0.45)])
        add("loat", [("loạt", 1.0)])
        add("loc", [("lọc", 1.0), ("lộc", 0.72), ("lốc", 0.55), ("lóc", 0.25)])
        add("long", [("lòng", 1.0), ("lỏng", 0.65), ("lông", 0.60), ("lồng", 0.60), ("lộng", 0.40), ("long", 0.50)])
        add("lot", [("lọt", 1.0), ("lót", 0.65), ("lột", 0.65)])
        add("lu", [("lũ", 1.0), ("lữ", 0.55), ("lừ", 0.30), ("lu", 0.30), ("lù", 0.25)])
        add("luan", [("luận", 1.0), ("luân", 0.65)])
        add("lung", [("lưng", 1.0), ("lũng", 0.45), ("lừng", 0.45), ("lúng", 0.45), ("lung", 0.40)])
        add("luoi", [("lưới", 1.0), ("lười", 0.85), ("lưỡi", 0.72)])
        add("luot", [("lượt", 1.0), ("lướt", 0.85)])
        add("luyen", [("luyện", 1.0), ("luyến", 0.35)])
        add("mac", [("mặc", 1.0), ("mắc", 0.88), ("mác", 0.50), ("mạc", 0.35)])
        add("mach", [("mạch", 1.0), ("mách", 0.45)])
        add("mam", [("mầm", 1.0), ("mắm", 0.75), ("mâm", 0.65)])
        add("mao", [("mạo", 1.0), ("mào", 0.35), ("mão", 0.25)])
        add("map", [("mập", 1.0), ("mấp", 0.25)])
        add("meo", [("mèo", 1.0), ("mẹo", 0.85), ("méo", 0.55)])
        add("mia", [("mía", 1.0), ("mỉa", 0.40)])
        add("mien", [("miễn", 1.0), ("miền", 0.90), ("miến", 0.45)])
        add("miet", [("miệt", 1.0)])
        add("min", [("mịn", 1.0), ("mìn", 0.35)])
        add("mit", [("mít", 1.0), ("mịt", 0.40)])
        add("moc", [("mọc", 1.0), ("mốc", 0.82), ("móc", 0.75), ("mộc", 0.65)])
        add("mon", [("món", 1.0), ("môn", 0.92), ("mòn", 0.55)])
        add("mong", [("mong", 1.0), ("mỏng", 0.78), ("móng", 0.65), ("mộng", 0.65), ("mông", 0.50)])
        add("muong", [("mường", 1.0), ("muỗng", 0.65)])
        add("mut", [("mứt", 1.0), ("mút", 0.55)])
        add("my", [("mỹ", 1.0), ("mỳ", 0.65)])
        add("nan", [("nạn", 1.0), ("nản", 0.78), ("nắn", 0.55), ("nặn", 0.45), ("nan", 0.35)])
        add("nap", [("nạp", 1.0), ("nắp", 0.75), ("nấp", 0.45)])
        add("nat", [("nát", 1.0), ("nạt", 0.25)])
        add("nau", [("nấu", 1.0), ("nâu", 0.72), ("náu", 0.25)])
        add("ne", [("nè", 1.0), ("né", 0.85), ("nể", 0.65)])
        add("nem", [("ném", 1.0), ("nếm", 0.72), ("nệm", 0.65), ("nem", 0.55)])
        add("neo", [("neo", 1.0), ("nẻo", 0.40)])
        add("nep", [("nếp", 1.0), ("nép", 0.35)])
        add("net", [("nét", 1.0), ("nết", 0.40)])
        add("nga", [("ngã", 1.0), ("ngà", 0.55), ("ngả", 0.60), ("nga", 0.65), ("ngá", 0.15)])
        add("ngac", [("ngạc", 1.0), ("ngắc", 0.30)])
        add("ngai", [("ngại", 1.0), ("ngài", 0.65), ("ngải", 0.25)])
        add("ngam", [("ngắm", 1.0), ("ngầm", 0.85), ("ngâm", 0.75), ("ngậm", 0.55), ("ngẫm", 0.55)])
        add("ngang", [("ngang", 1.0), ("ngàng", 0.35), ("ngãng", 0.15)])
        add("nganh", [("ngành", 1.0)])
        add("ngao", [("ngạo", 1.0), ("ngào", 0.55), ("ngao", 0.40)])
        add("ngap", [("ngập", 1.0), ("ngáp", 0.45)])
        add("ngat", [("ngắt", 1.0), ("ngất", 0.65), ("ngạt", 0.55), ("ngát", 0.50)])
        add("nghen", [("nghẽn", 1.0), ("nghẹn", 0.78)])
        add("ngheo", [("nghèo", 1.0)])
        add("nghia", [("nghĩa", 1.0)])
        add("nghich", [("nghịch", 1.0)])
        add("nghieng", [("nghiêng", 1.0)])
        add("ngo", [("ngõ", 1.0), ("ngờ", 0.92), ("ngô", 0.75), ("ngỡ", 0.72), ("ngó", 0.55), ("ngộ", 0.65), ("ngớ", 0.30)])
        add("ngoac", [("ngoặc", 1.0)])
        add("ngoan", [("ngoan", 1.0), ("ngoạn", 0.55)])
        add("ngoc", [("ngọc", 1.0), ("ngốc", 0.75), ("ngóc", 0.35)])
        add("ngong", [("ngóng", 1.0), ("ngọng", 0.50), ("ngông", 0.35)])
        add("nguoc", [("ngược", 1.0)])
        add("nguon", [("nguồn", 1.0)])
        add("nguong", [("ngưỡng", 1.0), ("ngượng", 0.65)])
        add("nguy", [("nguy", 1.0), ("ngụy", 0.45)])
        add("nham", [("nhằm", 1.0), ("nhầm", 0.92), ("nhắm", 0.70), ("nhám", 0.35), ("nhảm", 0.45), ("nhậm", 0.30)])
        add("nhay", [("nhảy", 1.0), ("nhạy", 0.85), ("nháy", 0.72), ("nhầy", 0.25)])
        add("nhiet", [("nhiệt", 1.0)])
        add("nhin", [("nhìn", 1.0), ("nhịn", 0.65)])
        add("nhip", [("nhịp", 1.0)])
        add("nhon", [("nhọn", 1.0), ("nhộn", 0.65), ("nhờn", 0.40), ("nhơn", 0.35)])
        add("nhuc", [("nhức", 1.0), ("nhục", 0.65)])
        add("nhuoc", [("nhược", 1.0)])
        add("nhuong", [("nhượng", 1.0), ("nhường", 0.92)])
        add("nhut", [("nhút", 1.0)])
        add("niem", [("niềm", 1.0), ("niêm", 0.55)])
        add("nien", [("niên", 1.0)])
        add("nin", [("nín", 1.0)])
        add("niu", [("níu", 1.0)])
        add("noc", [("nóc", 1.0), ("nọc", 0.40)])
        add("nom", [("nôm", 1.0), ("nồm", 0.45), ("nộm", 0.55)])
        add("non", [("non", 1.0), ("nón", 0.82), ("nôn", 0.65), ("nỡn", 0.15)])
        add("not", [("nốt", 1.0), ("nót", 0.25)])
        add("nu", [("nữ", 1.0), ("nụ", 0.70)])
        add("nuc", [("nức", 1.0), ("nực", 0.55)])
        add("nuoi", [("nuôi", 1.0)])
        add("nuong", [("nướng", 1.0), ("nương", 0.65)])
        add("nuot", [("nuốt", 1.0), ("nuột", 0.40)])
        add("oai", [("oai", 1.0), ("oải", 0.55)])
        add("oan", [("oan", 1.0), ("oán", 0.65)])
        add("oanh", [("oanh", 1.0), ("oánh", 0.55)])
        add("oc", [("óc", 1.0), ("ốc", 0.85)])
        add("om", [("ôm", 1.0), ("ốm", 0.88), ("ỏm", 0.20), ("om", 0.35)])
        add("op", [("ốp", 1.0), ("ọp", 0.25)])
        add("ot", [("ớt", 1.0)])
        add("pha", [("pha", 1.0), ("phá", 0.95), ("phà", 0.45), ("phả", 0.30)])
        add("phach", [("phách", 1.0)])
        add("phau", [("phẫu", 1.0)])
        add("phep", [("phép", 1.0)])
        add("phien", [("phiên", 1.0), ("phiền", 0.88), ("phiến", 0.40)])
        add("phieu", [("phiếu", 1.0), ("phiêu", 0.65)])
        add("phia", [("phía", 1.0)])
        add("phu", [("phụ", 1.0), ("phủ", 0.90), ("phú", 0.82), ("phù", 0.78), ("phu", 0.45)])
        add("phun", [("phun", 1.0), ("phũn", 0.05)])
        add("phung", [("phụng", 1.0), ("phùng", 0.55), ("phung", 0.45)])
        add("phuoc", [("phước", 1.0)])
        add("pin", [("pin", 1.0)])
        add("quac", [("quắc", 1.0), ("quạc", 0.25)])
        add("quai", [("quái", 1.0), ("quai", 0.65), ("quải", 0.25)])
        add("quang", [("quảng", 1.0), ("quang", 0.88), ("quàng", 0.50), ("quặng", 0.45), ("quăng", 0.45), ("quáng", 0.30)])
        add("quanh", [("quanh", 1.0), ("quạnh", 0.35)])
        add("que", [("quê", 1.0), ("que", 0.65), ("quẻ", 0.40), ("què", 0.35)])
        add("quet", [("quét", 1.0), ("quẹt", 0.65), ("quệt", 0.35)])
        add("quoc", [("quốc", 1.0)])
        add("quyt", [("quýt", 1.0), ("quỵt", 0.35)])
        add("quynh", [("quỳnh", 1.0)])
        add("rac", [("rác", 1.0), ("rắc", 0.72), ("rặc", 0.25)])
        add("rach", [("rách", 1.0), ("rạch", 0.55)])
        add("rai", [("rải", 1.0), ("rãi", 0.75)])
        add("ram", [("rằm", 1.0), ("rầm", 0.65), ("rậm", 0.60), ("rám", 0.35)])
        add("ran", [("rắn", 1.0), ("rặn", 0.35), ("rán", 0.65), ("rạn", 0.50), ("rần", 0.40)])
        add("rao", [("rao", 1.0), ("rào", 0.82), ("ráo", 0.55), ("rảo", 0.35)])
        add("rap", [("rạp", 1.0), ("ráp", 0.72), ("rập", 0.45)])
        add("re", [("rẻ", 1.0), ("rẽ", 0.78), ("rễ", 0.65), ("rể", 0.45), ("rè", 0.30), ("ré", 0.25)])
        add("ren", [("rèn", 1.0), ("rên", 0.55), ("ren", 0.55)])
        add("reo", [("reo", 1.0), ("réo", 0.55)])
        add("ret", [("rét", 1.0)])
        add("ri", [("rỉ", 1.0), ("rí", 0.40), ("rì", 0.50)])
        add("ria", [("rìa", 1.0), ("ria", 0.40)])
        add("rim", [("rim", 1.0)])
        add("rinh", [("rình", 1.0), ("rinh", 0.65)])
        add("rit", [("rít", 1.0), ("rịt", 0.25)])
        add("roc", [("róc", 1.0), ("rọc", 0.55)])
        add("rom", [("rơm", 1.0), ("ròm", 0.45), ("róm", 0.25)])
        add("ron", [("rộn", 1.0), ("rờn", 0.45), ("rợn", 0.45), ("rốn", 0.40)])
        add("rot", [("rót", 1.0), ("rớt", 0.92)])
        add("ru", [("rủ", 1.0), ("ru", 0.65), ("rũ", 0.45), ("rù", 0.30)])
        add("rua", [("rửa", 1.0), ("rùa", 0.65), ("rủa", 0.30)])
        add("ruc", [("rực", 1.0), ("rục", 0.45), ("rúc", 0.35)])
        add("rui", [("rủi", 1.0), ("rùi", 0.20)])
        add("rum", [("rùm", 1.0), ("rúm", 0.45)])
        add("run", [("run", 1.0), ("rùn", 0.35), ("rủn", 0.35)])
        add("ruoc", [("rước", 1.0)])
        add("ruoi", [("rưỡi", 1.0), ("ruồi", 0.60), ("rưới", 0.55), ("rươi", 0.35)])
        add("ruong", [("ruộng", 1.0), ("rương", 0.55)])
        add("ruot", [("ruột", 1.0), ("rượt", 0.55)])
        add("rut", [("rút", 1.0), ("rụt", 0.55)])
        add("sa", [("sa", 1.0), ("sà", 0.45), ("sả", 0.50), ("sạ", 0.25)])
        add("sam", [("sắm", 1.0), ("sấm", 0.72), ("sâm", 0.70), ("sầm", 0.50), ("sạm", 0.45), ("sám", 0.45)])
        add("sap", [("sắp", 1.0), ("sập", 0.72), ("sáp", 0.65)])
        add("sat", [("sát", 1.0), ("sắt", 0.88), ("sạt", 0.45)])
        add("say", [("say", 1.0), ("sấy", 0.72), ("sây", 0.20)])
        add("sen", [("sen", 1.0), ("sến", 0.45), ("sên", 0.40)])
        add("set", [("sét", 1.0), ("sệt", 0.40)])
        add("si", [("sĩ", 1.0), ("sỉ", 0.75), ("si", 0.50), ("sì", 0.30)])
        add("siet", [("siết", 1.0)])
        add("soc", [("sóc", 1.0), ("sốc", 0.90), ("sọc", 0.65)])
        add("soi", [("sôi", 1.0), ("soi", 0.85), ("sợi", 0.82), ("sỏi", 0.65), ("sói", 0.55)])
        add("son", [("sơn", 1.0), ("son", 0.82), ("sờn", 0.30)])
        add("sot", [("sốt", 1.0), ("sót", 0.85), ("sột", 0.20)])
        add("suc", [("sức", 1.0), ("súc", 0.55), ("sục", 0.45)])
        add("sui", [("sủi", 1.0), ("sùi", 0.40)])
        add("sum", [("sum", 1.0), ("sùm", 0.30)])
        add("sun", [("sụn", 1.0), ("sún", 0.35)])
        add("sung", [("súng", 1.0), ("sung", 0.82), ("sưng", 0.65), ("sừng", 0.55), ("sùng", 0.40)])
        add("suoi", [("suối", 1.0), ("sưởi", 0.65)])
        add("suon", [("sườn", 1.0), ("suôn", 0.72)])
        add("suong", [("sướng", 1.0), ("sương", 0.85)])
        add("suot", [("suốt", 1.0)])
        add("sup", [("sụp", 1.0), ("súp", 0.75)])
        add("sut", [("sút", 1.0), ("sụt", 0.78), ("sứt", 0.35)])
        add("suy", [("suy", 1.0), ("suý", 0.15)])
        add("suyt", [("suýt", 1.0)])
        add("tach", [("tách", 1.0), ("tạch", 0.35)])
        add("tan", [("tận", 1.0), ("tân", 0.88), ("tấn", 0.82), ("tàn", 0.72), ("tần", 0.72), ("tan", 0.68), ("tán", 0.60), ("tản", 0.55)])
        add("tanh", [("tánh", 1.0), ("tanh", 0.75), ("tành", 0.35)])
        add("te", [("tệ", 1.0), ("tế", 0.92), ("té", 0.65), ("tê", 0.60), ("tẻ", 0.40)])
        add("ten", [("tên", 1.0)])
        add("tet", [("tết", 1.0), ("tét", 0.45)])
        add("thac", [("thắc", 1.0), ("thác", 0.75), ("thạc", 0.60)])
        add("thach", [("thách", 1.0), ("thạch", 0.75)])
        add("tham", [("tham", 1.0), ("thăm", 0.92), ("thấm", 0.78), ("thầm", 0.75), ("thảm", 0.65), ("thẩm", 0.72), ("thắm", 0.50), ("thậm", 0.75)])
        add("thao", [("thảo", 1.0), ("tháo", 0.82), ("thao", 0.80), ("thạo", 0.72)])
        add("thau", [("thấu", 1.0), ("thâu", 0.65), ("thau", 0.45), ("thầu", 0.72)])
        add("then", [("then", 1.0), ("thẹn", 0.65)])
        add("thep", [("thép", 1.0)])
        add("thieu", [("thiếu", 1.0), ("thiểu", 0.78), ("thiêu", 0.45), ("thiều", 0.35)])
        add("thinh", [("thịnh", 1.0), ("thính", 0.72), ("thỉnh", 0.78)])
        add("thiu", [("thiu", 1.0)])
        add("tho", [("thợ", 1.0), ("thở", 0.92), ("thơ", 0.88), ("thô", 0.75), ("thọ", 0.65), ("thỏ", 0.60), ("thờ", 0.70), ("thổ", 0.55)])
        add("thoa", [("thỏa", 1.0), ("thoa", 0.72)])
        add("thoang", [("thoáng", 1.0), ("thoảng", 0.65)])
        add("thoat", [("thoát", 1.0)])
        add("thoc", [("thóc", 1.0), ("thọc", 0.45)])
        add("thom", [("thơm", 1.0)])
        add("thon", [("thôn", 1.0), ("thon", 0.72), ("thổn", 0.35)])
        add("thot", [("thốt", 1.0), ("thớt", 0.60)])
        add("thua", [("thua", 1.0), ("thừa", 0.95), ("thưa", 0.85), ("thửa", 0.45)])
        add("thuan", [("thuận", 1.0), ("thuần", 0.82)])
        add("thuat", [("thuật", 1.0)])
        add("thue", [("thuê", 1.0), ("thuế", 0.92)])
        add("thui", [("thúi", 1.0), ("thui", 0.50)])
        add("thung", [("thùng", 1.0), ("thủng", 0.65), ("thung", 0.55), ("thững", 0.25)])
        add("thuoc", [("thuộc", 1.0), ("thuốc", 0.92), ("thước", 0.78)])
        add("thuo", [("thuở", 1.0)])
        add("thut", [("thụt", 1.0)])
        add("thuy", [("thủy", 1.0), ("thúy", 0.60), ("thụy", 0.45), ("thùy", 0.55)])
        add("thuyen", [("thuyền", 1.0), ("thuyên", 0.45)])
        add("thuyet", [("thuyết", 1.0)])
        add("ti", [("tỉ", 1.0), ("tí", 0.92), ("ti", 0.65), ("tì", 0.40)])
        add("tia", [("tia", 1.0), ("tỉa", 0.55), ("tía", 0.45)])
        add("tiec", [("tiếc", 1.0), ("tiệc", 0.85)])
        add("tiet", [("tiết", 1.0), ("tiệt", 0.35)])
        add("toa", [("tòa", 1.0), ("tỏa", 0.75), ("tọa", 0.75)])
        add("toac", [("toạc", 1.0)])
        add("toat", [("toát", 1.0)])
        add("tom", [("tôm", 1.0), ("tóm", 0.88), ("tỏm", 0.20)])
        add("ton", [("tốn", 1.0), ("tồn", 0.92), ("tôn", 0.85), ("tổn", 0.80)])
        add("top", [("tốp", 1.0), ("tóp", 0.45)])
        add("tran", [("trận", 1.0), ("trần", 0.88), ("tràn", 0.80), ("trấn", 0.65), ("trân", 0.75), ("trăn", 0.50)])
        add("tranh", [("tránh", 1.0), ("tranh", 0.92)])
        add("trao", [("trao", 1.0), ("trào", 0.72), ("tráo", 0.40)])
        add("trat", [("trật", 1.0), ("trát", 0.45)])
        add("trau", [("trâu", 1.0), ("trầu", 0.45), ("trau", 0.55)])
        add("treo", [("treo", 1.0), ("trèo", 0.78), ("trẹo", 0.35)])
        add("triet", [("triệt", 1.0)])
        add("trim", [("trĩm", 0.10)])
        add("trom", [("trộm", 1.0)])
        add("tron", [("trọn", 1.0), ("tròn", 0.90), ("trốn", 0.78), ("trộn", 0.75), ("trơn", 0.72)])
        add("tru", [("trừ", 1.0), ("trú", 0.75), ("trụ", 0.80), ("trữ", 0.75), ("trù", 0.40)])
        add("truc", [("trực", 1.0), ("trục", 0.75), ("trúc", 0.65)])
        add("trui", [("trụi", 1.0)])
        add("truyen", [("truyền", 1.0), ("truyện", 0.90)])
        add("tuoi", [("tuổi", 1.0), ("tươi", 0.88), ("tưới", 0.60)])
        add("tuon", [("tuôn", 1.0)])
        add("tuot", [("tuột", 1.0), ("tuốt", 0.55)])
        add("tut", [("tụt", 1.0)])
        add("tuyen", [("tuyến", 1.0), ("tuyển", 0.92), ("tuyên", 0.82)])
        add("u", [("ủ", 1.0), ("ù", 0.55), ("u", 0.55), ("ứ", 0.45), ("ừ", 0.85), ("ư", 0.40), ("ú", 0.35)])
        add("ua", [("ưa", 1.0), ("ùa", 0.65), ("ứa", 0.45), ("úa", 0.35)])
        add("uc", [("ức", 1.0), ("úc", 0.75)])
        add("ui", [("ủi", 1.0), ("ùi", 0.25)])
        add("um", [("um", 1.0), ("ùm", 0.45), ("ủm", 0.25)])
        add("un", [("ùn", 1.0), ("ủn", 0.40)])
        add("uoc", [("ước", 1.0)])
        add("uom", [("ươm", 1.0), ("ướm", 0.45)])
        add("uon", [("uốn", 1.0), ("ưỡn", 0.40)])
        add("uot", [("ướt", 1.0)])
        add("up", [("úp", 1.0), ("ụp", 0.35)])
        add("ut", [("út", 1.0)])
        add("uy", [("uy", 1.0), ("ủy", 0.85)])
        add("vac", [("vác", 1.0), ("vạc", 0.35)])
        add("vach", [("vạch", 1.0), ("vách", 0.82)])
        add("vam", [("vạm", 1.0)])
        add("vang", [("vàng", 1.0), ("vắng", 0.85), ("vang", 0.75), ("vâng", 0.90), ("văng", 0.55), ("vạng", 0.20)])
        add("vanh", [("vành", 1.0)])
        add("vat", [("vật", 1.0), ("vắt", 0.65), ("vất", 0.75), ("vạt", 0.35)])
        add("ven", [("vẹn", 1.0), ("ven", 0.80), ("vén", 0.55)])
        add("vet", [("vết", 1.0), ("vét", 0.55), ("vẹt", 0.45)])
        add("via", [("vía", 1.0), ("vỉa", 0.65)])
        add("vinh", [("vinh", 1.0), ("vĩnh", 0.85), ("vịnh", 0.75)])
        add("vit", [("vịt", 1.0), ("vít", 0.65)])
        add("voc", [("vóc", 1.0), ("vọc", 0.45)])
        add("vom", [("vòm", 1.0)])
        add("von", [("vốn", 1.0), ("vồn", 0.30)])
        add("vong", [("vòng", 1.0), ("vọng", 0.90), ("võng", 0.55), ("vống", 0.30)])
        add("vot", [("vọt", 1.0), ("vợt", 0.82), ("vớt", 0.75)])
        add("vuc", [("vực", 1.0), ("vục", 0.25)])
        add("vung", [("vùng", 1.0), ("vững", 0.88), ("vũng", 0.65), ("vựng", 0.60), ("vung", 0.55)])
        add("vuon", [("vườn", 1.0), ("vươn", 0.82)])
        add("vuong", [("vương", 1.0), ("vuông", 0.88), ("vướng", 0.82), ("vượng", 0.65)])
        add("vuot", [("vượt", 1.0), ("vuốt", 0.75)])
        add("vut", [("vút", 1.0), ("vứt", 0.85), ("vụt", 0.65)])
        add("xam", [("xám", 1.0), ("xâm", 0.85), ("xăm", 0.70), ("xầm", 0.30)])
        add("xan", [("xắn", 1.0), ("xần", 0.25)])
        add("xang", [("xăng", 1.0), ("xang", 0.35)])
        add("xanh", [("xanh", 1.0), ("xành", 0.15)])
        add("xao", [("xào", 1.0), ("xáo", 0.72), ("xạo", 0.65), ("xảo", 0.45)])
        add("xap", [("xấp", 1.0), ("xập", 0.45)])
        add("xat", [("xát", 1.0)])
        add("xen", [("xen", 1.0), ("xén", 0.55)])
        add("xeo", [("xéo", 1.0), ("xẻo", 0.45)])
        add("xep", [("xếp", 1.0), ("xẹp", 0.55)])
        add("xet", [("xét", 1.0)])
        add("xi", [("xỉ", 1.0), ("xì", 0.75), ("xí", 0.70), ("xi", 0.60)])
        add("xich", [("xích", 1.0)])
        add("xien", [("xiên", 1.0)])
        add("xiet", [("xiết", 1.0)])
        add("xinh", [("xinh", 1.0)])
        add("xit", [("xịt", 1.0), ("xít", 0.45)])
        add("xo", [("xô", 1.0), ("xơ", 0.78), ("xổ", 0.75), ("xỏ", 0.65), ("xớ", 0.35), ("xò", 0.25)])
        add("xoai", [("xoài", 1.0)])
        add("xoan", [("xoắn", 1.0), ("xoan", 0.65)])
        add("xoay", [("xoay", 1.0), ("xoáy", 0.82)])
        add("xoc", [("xóc", 1.0), ("xộc", 0.45)])
        add("xoi", [("xôi", 1.0), ("xới", 0.65), ("xói", 0.55)])
        add("xom", [("xóm", 1.0), ("xồm", 0.30)])
        add("xon", [("xôn", 1.0), ("xốn", 0.45)])
        add("xot", [("xót", 1.0)])
        add("xuan", [("xuân", 1.0)])
        add("xuc", [("xúc", 1.0), ("xực", 0.35)])
        add("xui", [("xui", 1.0), ("xúi", 0.65), ("xụi", 0.40)])
        add("xung", [("xung", 1.0), ("xứng", 0.92), ("xưng", 0.75), ("xùng", 0.20)])
        add("xuoi", [("xuôi", 1.0)])
        add("xuyen", [("xuyên", 1.0)])
        add("yen", [("yên", 1.0), ("yến", 0.72)])
        add("yet", [("yết", 1.0)])
        add("cam", [("cảm", 1.0), ("cầm", 0.68), ("cấm", 0.55), ("cam", 0.50), ("cắm", 0.45), ("cám", 0.35)])
        add("on", [("ơn", 1.0), ("ổn", 0.85), ("ồn", 0.45), ("ôn", 0.40), ("ớn", 0.18)])
        add("ben", [("bên", 1.0), ("bến", 0.68), ("bền", 0.65), ("bẽn", 0.15)])
        add("hy", [("hy", 1.0)])
        add("nhau", [("nhau", 1.0), ("nhậu", 0.55), ("nhàu", 0.25)])
        add("nhuan", [("nhuận", 1.0)])
        add("thien", [("thiện", 1.0), ("thiên", 0.90), ("thiền", 0.55)])
        add("tue", [("tuệ", 1.0)])
        add("tung", [("từng", 1.0), ("tùng", 0.65), ("tung", 0.60), ("túng", 0.40), ("tụng", 0.35)])

        return map
    }()

    // MARK: - High-Frequency Vietnamese Bigrams (400+ pairs)

    /// High-frequency Vietnamese bigrams: `"<prevSurface> <currSurface>"` -> weight.
    public static let vietnameseBigrams: [String: Double] = {
        var map: [String: Double] = [:]
        map.reserveCapacity(460)

        func add(_ pairs: [(String, Double)]) {
            for (k, v) in pairs {
                map[k] = v
            }
        }

        // Time, Calendar & Greetings
        add([
            ("hôm nay", 10.0), ("hôm qua", 10.0), ("ngày mai", 10.0), ("ngày kia", 8.5),
            ("sáng nay", 9.5), ("trưa nay", 9.0), ("chiều nay", 9.5), ("tối nay", 9.5), ("đêm nay", 9.0),
            ("tối qua", 9.0), ("sáng mai", 9.0), ("chiều mai", 9.0), ("tuần này", 9.5), ("tuần trước", 9.5),
            ("tuần sau", 9.5), ("tháng này", 9.5), ("tháng trước", 9.5), ("tháng sau", 9.5),
            ("năm nay", 9.5), ("năm ngoái", 9.5), ("năm sau", 9.5), ("năm mới", 9.5),
            ("cuối tuần", 9.5), ("đầu tuần", 9.0), ("cuối tháng", 9.0), ("cuối năm", 9.0),
            ("mỗi ngày", 9.0), ("hàng ngày", 9.0), ("hiện tại", 9.5), ("tương lai", 9.5),
            ("quá khứ", 9.0), ("thời gian", 10.0), ("thời điểm", 9.0), ("lúc này", 9.0), ("lúc đó", 9.0),
            ("khi nào", 9.5), ("bao giờ", 9.5), ("bây giờ", 10.0), ("ngay bây", 8.5), ("ngay lập", 8.5),
            ("lập tức", 9.0), ("trước đây", 9.0), ("sau này", 9.5), ("từ trước", 8.5), ("về sau", 8.5),
            ("cảm ơn", 10.0), ("ơn bạn", 9.5), ("ơn anh", 9.0), ("ơn chị", 9.0), ("ơn em", 9.0),
            ("xin lỗi", 10.0), ("xin chào", 10.0), ("chào bạn", 9.5), ("chào anh", 9.0), ("chào em", 9.0),
            ("tạm biệt", 10.0), ("hẹn gặp", 10.0), ("gặp lại", 9.5), ("chúc mừng", 9.5), ("chúc bạn", 9.0)
        ])

        // Language, Typing, Software & Tech
        add([
            ("tiếng việt", 10.0), ("tiếng anh", 10.0), ("việt nam", 10.0), ("không dấu", 10.0),
            ("có dấu", 9.5), ("bỏ dấu", 9.5), ("gõ dấu", 9.5), ("bộ gõ", 10.0), ("gõ tiếng", 9.5),
            ("bàn phím", 10.0), ("phím tắt", 9.5), ("con trỏ", 9.0), ("màn hình", 10.0), ("cửa sổ", 9.5),
            ("ứng dụng", 10.0), ("phần mềm", 10.0), ("phần cứng", 9.5), ("hệ thống", 10.0),
            ("hệ điều", 9.0), ("điều hành", 9.5), ("máy tính", 10.0), ("điện thoại", 10.0),
            ("thông minh", 10.0), ("tự động", 10.0), ("thủ công", 9.5), ("cục bộ", 9.5),
            ("mật khẩu", 10.0), ("bảo mật", 10.0), ("tài khoản", 10.0), ("đăng nhập", 10.0),
            ("đăng ký", 10.0), ("đăng xuất", 9.5), ("quyền truy", 9.0), ("truy cập", 9.5),
            ("cài đặt", 10.0), ("cấu hình", 10.0), ("kết nối", 10.0), ("đồng bộ", 9.5),
            ("cập nhật", 10.0), ("nâng cấp", 9.5), ("sao lưu", 9.5), ("phục hồi", 9.5),
            ("khởi động", 9.5), ("tắt máy", 9.0), ("dữ liệu", 10.0), ("cơ sở", 9.5), ("sở dữ", 9.0),
            ("mô hình", 10.0), ("ngữ cảnh", 10.0), ("ngôn ngữ", 10.0), ("từ vựng", 9.5),
            ("từ điển", 9.5), ("văn bản", 10.0), ("tài liệu", 10.0), ("thư mục", 9.5), ("tệp tin", 9.5),
            ("tin nhắn", 10.0), ("thông báo", 10.0), ("báo lỗi", 9.5), ("sửa lỗi", 10.0),
            ("tìm kiếm", 10.0), ("xử lý", 10.0), ("phân tích", 10.0), ("tổng hợp", 9.5),
            ("tối ưu", 9.5), ("hiệu năng", 9.5), ("hiệu suất", 9.5), ("tốc độ", 9.5),
            ("trí tuệ", 9.5), ("nhân tạo", 9.5), ("học máy", 9.5), ("học tập", 9.5),
            ("lập trình", 10.0), ("phát triển", 10.0), ("thiết kế", 10.0), ("giao diện", 10.0),
            ("trải nghiệm", 10.0), ("người dùng", 10.0), ("tính năng", 10.0), ("chức năng", 10.0),
            ("phiên bản", 10.0), ("mã nguồn", 9.5), ("bảo trì", 9.0), ("vận hành", 9.0),
            ("triển khai", 9.5), ("kiểm thử", 9.5), ("tích hợp", 9.5), ("mở rộng", 9.5)
        ])

        // Work, Planning, Business & Office
        add([
            ("làm việc", 10.0), ("đi làm", 10.0), ("công việc", 10.0), ("về nhà", 10.0),
            ("đi học", 9.5), ("đi chơi", 9.5), ("đi ăn", 9.5), ("đi ngủ", 9.5), ("đi mua", 9.0),
            ("kế hoạch", 10.0), ("mục tiêu", 10.0), ("lộ trình", 10.0), ("dự án", 10.0),
            ("họp nhóm", 9.5), ("cuộc họp", 9.5), ("phòng họp", 9.0), ("báo cáo", 10.0),
            ("kiểm tra", 10.0), ("đánh giá", 10.0), ("đề xuất", 9.5), ("giải pháp", 10.0),
            ("giải quyết", 10.0), ("vấn đề", 10.0), ("trường hợp", 10.0), ("tình huống", 9.5),
            ("khả năng", 10.0), ("cân nhắc", 10.0), ("hướng dẫn", 10.0), ("sử dụng", 10.0),
            ("hoàn toàn", 10.0), ("hoàn thành", 10.0), ("chính xác", 10.0), ("bình thường", 10.0),
            ("đặc biệt", 10.0), ("tiếp theo", 10.0), ("tiếp tục", 10.0), ("bắt đầu", 10.0),
            ("kết thúc", 10.0), ("kết quả", 10.0), ("thành công", 10.0), ("thất bại", 9.5),
            ("hiệu quả", 10.0), ("chất lượng", 10.0), ("số lượng", 9.5), ("chi phí", 9.5),
            ("doanh thu", 9.5), ("lợi nhuận", 9.5), ("khách hàng", 10.0), ("đối tác", 9.5),
            ("công ty", 10.0), ("doanh nghiệp", 10.0), ("sản phẩm", 10.0), ("dịch vụ", 10.0),
            ("thị trường", 10.0), ("chiến lược", 9.5), ("quy trình", 10.0), ("tiêu chuẩn", 9.5),
            ("yêu cầu", 10.0), ("nhân viên", 10.0), ("quản lý", 10.0), ("lãnh đạo", 9.5),
            ("đồng nghiệp", 9.5), ("đội ngũ", 9.5), ("cộng đồng", 9.5), ("hợp tác", 9.5),
            ("hỗ trợ", 10.0), ("phản hồi", 10.0), ("góp ý", 9.5), ("thảo luận", 9.5),
            ("trao đổi", 9.5), ("thống nhất", 9.5), ("xác nhận", 10.0), ("phê duyệt", 9.5),
            ("ưu tiên", 9.5), ("quan trọng", 10.0), ("cần thiết", 10.0), ("phù hợp", 10.0),
            ("chi tiết", 10.0), ("cụ thể", 10.0), ("rõ ràng", 10.0), ("ngắn gọn", 9.5),
            ("đầy đủ", 10.0), ("an toàn", 10.0), ("ổn định", 10.0), ("tiện lợi", 9.5),
            ("kinh nghiệm", 10.0), ("kiến thức", 10.0), ("kỹ năng", 10.0), ("tư duy", 9.5),
            ("sáng tạo", 9.5), ("chuyên nghiệp", 9.5), ("trách nhiệm", 10.0), ("vai trò", 9.5),
            ("vị trí", 9.5), ("môi trường", 9.5), ("điều kiện", 10.0), ("nguyên tắc", 9.5),
            ("chính sách", 9.5), ("quyết định", 10.0), ("lựa chọn", 10.0), ("thay đổi", 10.0),
            ("cải thiện", 10.0), ("tăng cường", 9.5), ("đảm bảo", 10.0), ("duy trì", 9.5)
        ])

        // Subject-Verb, Pronoun & Auxiliary Collocations
        add([
            ("tôi muốn", 9.5), ("tôi đang", 9.5), ("tôi sẽ", 9.5), ("tôi đã", 9.5),
            ("tôi nghĩ", 9.5), ("tôi biết", 9.5), ("tôi cần", 9.5), ("tôi thấy", 9.5),
            ("tôi có", 9.5), ("tôi không", 9.5), ("tôi đi", 9.5), ("tôi làm", 9.5),
            ("tôi thích", 9.5), ("tôi rất", 9.5), ("tôi cũng", 9.5), ("tôi vừa", 9.0),
            ("tôi xem", 9.0), ("tôi mua", 9.0), ("tôi ăn", 9.0), ("tôi viết", 9.0),
            ("mình muốn", 9.5), ("mình đang", 9.5), ("mình sẽ", 9.5), ("mình đã", 9.5),
            ("mình nghĩ", 9.5), ("mình thấy", 9.5), ("mình cần", 9.5), ("mình có", 9.5),
            ("mình không", 9.5), ("mình đi", 9.0), ("mình làm", 9.0), ("mình rất", 9.0),
            ("bạn có", 9.5), ("bạn ơi", 9.5), ("bạn đang", 9.5), ("bạn muốn", 9.5),
            ("bạn cần", 9.5), ("bạn đã", 9.5), ("bạn sẽ", 9.5), ("bạn giúp", 9.5),
            ("bạn xem", 9.0), ("bạn thấy", 9.0), ("bạn biết", 9.0), ("bạn rất", 9.0),
            ("anh ơi", 9.0), ("anh đang", 9.0), ("anh có", 9.0), ("anh đã", 9.0), ("anh sẽ", 9.0),
            ("em ơi", 9.0), ("em đang", 9.0), ("em có", 9.0), ("em đã", 9.0), ("em sẽ", 9.0),
            ("chị ơi", 9.0), ("chị có", 9.0), ("chị đang", 9.0),
            ("chúng ta", 10.0), ("chúng tôi", 10.0), ("chúng mình", 9.5), ("mọi người", 10.0),
            ("mọi thứ", 9.5), ("tất cả", 10.0), ("người khác", 9.5), ("người thân", 9.0),
            ("gia đình", 10.0), ("bạn bè", 9.5), ("bản thân", 9.5), ("chính mình", 9.0),
            ("nay tôi", 8.5), ("nay mình", 8.5), ("nay bạn", 8.5), ("nay trời", 9.0)
        ])

        // Negations, Modals, Questions & Grammar Connectors
        add([
            ("không có", 10.0), ("không cần", 10.0), ("không phải", 10.0), ("không thể", 10.0),
            ("không biết", 10.0), ("không được", 10.0), ("không sao", 9.5), ("không nên", 9.5),
            ("không muốn", 9.5), ("không thích", 9.5), ("không hiểu", 9.5), ("không thấy", 9.5),
            ("không còn", 9.5), ("không gì", 9.0), ("không bao", 9.0), ("không đúng", 9.5),
            ("không đủ", 9.5), ("không cần", 9.5), ("chưa có", 9.5), ("chưa biết", 9.5),
            ("chưa xong", 9.5), ("chưa được", 9.5), ("chưa từng", 9.5), ("chưa bao", 9.0),
            ("có thể", 10.0), ("có vẻ", 9.5), ("có lẽ", 9.5), ("có khi", 9.0), ("có phải", 9.5),
            ("có gì", 9.5), ("có ai", 9.0), ("có nhiều", 9.0), ("có một", 9.0), ("có nên", 9.0),
            ("phải không", 9.5), ("đúng không", 9.5), ("được không", 9.5), ("được chưa", 9.5),
            ("xong chưa", 9.5), ("xong rồi", 9.5), ("được rồi", 9.5), ("biết rồi", 9.0),
            ("đủ rồi", 9.0), ("tốt rồi", 9.0), ("thôi nhé", 9.0), ("nhé bạn", 8.5),
            ("như thế", 10.0), ("thế nào", 10.0), ("như vậy", 10.0), ("như nhau", 9.5),
            ("tại sao", 10.0), ("vì sao", 9.5), ("làm sao", 9.5), ("ra sao", 9.5),
            ("bao nhiêu", 10.0), ("ở đâu", 10.0), ("đi đâu", 9.5), ("đâu rồi", 9.0),
            ("từ đâu", 9.0), ("cái gì", 9.5), ("làm gì", 9.5), ("việc gì", 9.0), ("gì đó", 9.0),
            ("gì vậy", 9.0), ("gì thế", 9.0), ("cái này", 9.5), ("cái đó", 9.5), ("điều này", 9.5),
            ("điều đó", 9.5), ("việc này", 9.5), ("việc đó", 9.5), ("lúc nào", 9.5), ("nào đó", 9.0),
            ("bởi vì", 10.0), ("cho nên", 9.5), ("vì vậy", 10.0), ("vì thế", 10.0),
            ("do đó", 10.0), ("tuy nhiên", 10.0), ("mặc dù", 10.0), ("nhưng mà", 9.5),
            ("nếu như", 9.5), ("nếu không", 9.5), ("miễn là", 9.0), ("trong khi", 10.0),
            ("sau khi", 10.0), ("trước khi", 10.0), ("ngay khi", 9.5), ("mỗi khi", 9.5),
            ("đồng thời", 9.5), ("ngoài ra", 10.0), ("bên cạnh", 10.0), ("cạnh đó", 9.5),
            ("thêm vào", 9.0), ("hơn nữa", 9.5), ("đặc biệt", 9.5), ("nhất là", 9.5),
            ("chẳng hạn", 9.5), ("ví dụ", 10.0), ("chính là", 9.5), ("tức là", 9.5),
            ("nghĩa là", 9.5), ("có nghĩa", 9.5), ("liên quan", 10.0), ("quan đến", 9.5),
            ("dựa trên", 9.5), ("dựa vào", 9.5), ("phụ thuộc", 9.5), ("thuộc vào", 9.5),
            ("so với", 10.0), ("đối với", 10.0), ("về mặt", 9.5), ("theo như", 9.5),
            ("nhờ vào", 9.0), ("thông qua", 10.0), ("trên máy", 9.0), ("trong máy", 9.0)
        ])

        // Intensifiers, Superlatives & Everyday Phrases
        add([
            ("rất tốt", 9.5), ("rất nhiều", 10.0), ("rất đẹp", 9.5), ("rất nhanh", 9.5),
            ("rất dễ", 9.5), ("rất khó", 9.5), ("rất hay", 9.5), ("rất vui", 9.5),
            ("rất quan", 9.0), ("rất cần", 9.0), ("rất thích", 9.5), ("rất sớm", 9.5),
            ("quá đẹp", 9.5), ("quá nhiều", 9.5), ("quá nhanh", 9.5), ("quá tốt", 9.5),
            ("quá trời", 9.5), ("đẹp quá", 9.5), ("tốt quá", 9.5), ("nhanh quá", 9.5),
            ("hay quá", 9.5), ("vui quá", 9.5), ("ngon quá", 9.5), ("mệt quá", 9.5),
            ("cực kỳ", 10.0), ("vô cùng", 10.0), ("thật sự", 10.0), ("thực sự", 10.0),
            ("mới nhất", 10.0), ("tốt nhất", 10.0), ("nhanh nhất", 10.0), ("lớn nhất", 9.5),
            ("nhỏ nhất", 9.5), ("cao nhất", 9.5), ("thấp nhất", 9.5), ("nhiều nhất", 9.5),
            ("ít nhất", 10.0), ("đầu tiên", 10.0), ("cuối cùng", 10.0), ("duy nhất", 10.0),
            ("quan trọng", 10.0), ("đáng kể", 9.5), ("đáng tin", 9.0), ("tuyệt vời", 10.0),
            ("xuất sắc", 10.0), ("hoàn hảo", 10.0), ("thoải mái", 10.0), ("tự nhiên", 10.0),
            ("ngẫu nhiên", 9.5), ("cẩn thận", 10.0), ("chắc chắn", 10.0), ("kiên nhẫn", 9.5),
            ("cà phê", 10.0), ("uống cà", 9.5), ("phê sáng", 9.0), ("trà sữa", 9.5),
            ("ăn sáng", 9.5), ("ăn trưa", 9.5), ("ăn tối", 9.5), ("ăn cơm", 9.5),
            ("ăn phở", 9.5), ("ăn bún", 9.0), ("bánh mì", 9.5), ("uống nước", 9.5),
            ("trời đẹp", 9.5), ("trời mưa", 9.5), ("trời nắng", 9.5), ("trời lạnh", 9.5),
            ("thời tiết", 10.0), ("sức khỏe", 10.0), ("tinh thần", 9.5), ("cuộc sống", 10.0),
            ("hạnh phúc", 10.0), ("bình an", 9.5), ("may mắn", 10.0), ("hy vọng", 10.0),
            ("xây dựng", 10.0), ("lưu trữ", 10.0), ("trữ cục", 9.0), ("người việt", 9.5),
            ("hà nội", 10.0), ("sài gòn", 10.0), ("đà nẵng", 10.0), ("hồ chí", 9.5), ("chí minh", 9.5)
        ])

        return map
    }()
}
