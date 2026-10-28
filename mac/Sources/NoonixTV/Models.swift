import Foundation

/// a movie, show or episode as the core hands it out; everything but the kind may be missing
struct Item: Decodable, Hashable, Identifiable {
    var kind: String
    var tmdb: Int?
    var title: String?
    var poster: String?
    var backdrop: String?
    var logo: String?
    var still: String?
    var overview: String?
    var year: Int?
    var rating: Double?
    var genres: [String]?
    var runtime: Int?
    var show: Int?
    var season: Int?
    var episode: Int?
    var episodeTitle: String?
    var progress: Double?
    var watched: Bool?
    var showTitle: String?
    var showOverview: String?
    var position: Double?
    var duration: Double?
    var airDate: String?
    var playbackId: Int?

    enum CodingKeys: String, CodingKey {
        case kind, title, poster, backdrop, logo, still, overview, year, rating, genres, runtime
        case show, season, episode, episodeTitle, progress, watched, showTitle, showOverview, position, duration, airDate, playbackId
        case tmdb = "id"
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "movie"
        tmdb = try? c.decode(Int.self, forKey: .tmdb)
        title = try? c.decode(String.self, forKey: .title)
        poster = try? c.decode(String.self, forKey: .poster)
        backdrop = try? c.decode(String.self, forKey: .backdrop)
        logo = try? c.decode(String.self, forKey: .logo)
        still = try? c.decode(String.self, forKey: .still)
        overview = try? c.decode(String.self, forKey: .overview)
        year = try? c.decode(Int.self, forKey: .year)
        rating = try? c.decode(Double.self, forKey: .rating)
        genres = try? c.decode([String].self, forKey: .genres)
        runtime = try? c.decode(Int.self, forKey: .runtime)
        show = try? c.decode(Int.self, forKey: .show)
        season = try? c.decode(Int.self, forKey: .season)
        episode = try? c.decode(Int.self, forKey: .episode)
        episodeTitle = try? c.decode(String.self, forKey: .episodeTitle)
        progress = try? c.decode(Double.self, forKey: .progress)
        watched = try? c.decode(Bool.self, forKey: .watched)
        showTitle = try? c.decode(String.self, forKey: .showTitle)
        showOverview = try? c.decode(String.self, forKey: .showOverview)
        position = try? c.decode(Double.self, forKey: .position)
        duration = try? c.decode(Double.self, forKey: .duration)
        airDate = try? c.decode(String.self, forKey: .airDate)
        playbackId = try? c.decode(Int.self, forKey: .playbackId)
    }

    /// a show to open on the details page (go to show from an episode)
    static func show(_ id: Int, title: String?, backdrop: String?, poster: String?) -> Item {
        var d: [String: Any] = ["kind": "show", "id": id]
        if let title { d["title"] = title }
        if let backdrop { d["backdrop"] = backdrop }
        if let poster { d["poster"] = poster }
        return try! JSONDecoder().decode(Item.self, from: JSONSerialization.data(withJSONObject: d))
    }

    /// back to the core's shape, for calls that take the item itself (home.dismiss)
    var json: [String: Any] {
        var d: [String: Any] = ["kind": kind]
        if let tmdb { d["id"] = tmdb }
        if let show { d["show"] = show }
        if let season { d["season"] = season }
        if let episode { d["episode"] = episode }
        if let title { d["title"] = title }
        if let showTitle { d["showTitle"] = showTitle }
        if let playbackId { d["playbackId"] = playbackId }
        return d
    }

    var id: String {
        kind == "episode" ? "e\(show ?? 0)-\(season ?? 0)-\(episode ?? 0)" : "\(kind)\(tmdb ?? 0)"
    }

    var isMovie: Bool { kind == "movie" }
    /// the show or movie this opens on the details page
    var detailsTarget: (kind: String, id: Int)? {
        if kind == "episode", let show { return ("show", show) }
        return tmdb.map { (kind, $0) }
    }
    var episodeCode: String? {
        guard let season, let episode else { return nil }
        return "S\(season) · E\(episode)"
    }
}

struct Row: Decodable, Identifiable, Hashable {
    var id: String
    var title: String
    var style: String
    var brand: String?
}

struct LibraryList: Decodable {
    var items: [Item]
}

struct Profile: Decodable, Identifiable, Hashable {
    var id: Int
    var name: String
    var color: String
    var trakt: String
    var avatar: String?
    /// trakt let go of this profile's login: sign in once more
    var traktRelogin: Bool?
}

struct Profiles: Decodable {
    var current: Int
    var profiles: [Profile]
}

struct SeasonInfo: Decodable, Hashable, Identifiable {
    var number: Int
    var name: String?
    var episodes: Int?
    var poster: String?
    var id: Int { number }
}

struct Details: Decodable {
    var item: Item
    var tagline: String?
    var certification: String?
    var network: String?
    var status: String?
    var seasons: [SeasonInfo]?
    var next: NextUp?
    var cast: [Person]?
    var more: [Item]?
    var nextAir: NextAir?

    struct NextUp: Decodable { var season: Int; var episode: Int }
    struct NextAir: Decodable { var airDate: String? }
    struct Person: Decodable, Hashable { var name: String?; var role: String?; var photo: String? }

    enum CodingKeys: String, CodingKey { case tagline, certification, network, status, seasons, next, cast, more, nextAir }

    init(from d: Decoder) throws {
        item = try Item(from: d)
        let c = try d.container(keyedBy: CodingKeys.self)
        tagline = try? c.decode(String.self, forKey: .tagline)
        certification = try? c.decode(String.self, forKey: .certification)
        network = try? c.decode(String.self, forKey: .network)
        status = try? c.decode(String.self, forKey: .status)
        seasons = try? c.decode([SeasonInfo].self, forKey: .seasons)
        next = try? c.decode(NextUp.self, forKey: .next)
        cast = try? c.decode([Person].self, forKey: .cast)
        more = try? c.decode([Item].self, forKey: .more)
        nextAir = try? c.decode(NextAir.self, forKey: .nextAir)
    }
}

struct Season: Decodable {
    var number: Int
    var episodes: [Item]
}

struct Source: Decodable, Identifiable {
    var addon: String
    var title: String
    var url: String?
    var filename: String?
    var size: UInt64?
    var resolution: Int
    var hdr: [String]
    var codec: String?
    var audio: [String]
    var cached: Bool?
    var service: String?
    var languages: [String]
    var channels: String?
    var group: String?
    var source: String?
    var infoHash: String?
    var fileIdx: Int?
    var seeders: Int?
    /// a file in the user's own library
    var local: Bool?
    /// "level" (above the picture quality level) or "seeders" (few people sharing)
    var warn: String?
    var id: String { (url ?? infoHash.map { "\($0):\(fileIdx ?? -1)" } ?? "") + title + addon }

    var detailLine: String {
        let gb: String? = size.map { b in
            let g = Double(b) / 1e9
            if b < 1_000_000_000 { return "\(max(1, Int((Double(b) / 1e6).rounded()))) MB" }
            return (b >= 10_000_000_000 ? String(format: "%.0f", g) : String(format: "%.1f", g)) + " GB"
        }
        let audio = audio.prefix(2).joined(separator: " ")
        return [codec, audio.isEmpty ? nil : audio, channels, gb, group, local == true ? Lc("This PC") : addon].compactMap { $0 }.joined(separator: "  ·  ")
    }

    var label: String {
        resolution >= 2160 ? L("4K") : resolution >= 1440 ? "1440p" : resolution > 0 ? "\(resolution)p" : "?"
    }
    var sizeText: String? {
        size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }
}

