import Foundation

/// Allocates short, human-readable directory names for new worktrees so
/// terminal prompts and agent TUIs show `…/jetline/vega` instead of a UUID.
///
/// Names are drawn from a fixed list of star names. Uniqueness is scoped to
/// one repo's worktree folder, and the filesystem is the source of truth: a
/// name is free exactly when no directory with that name exists. That
/// automatically accounts for active workspaces, archived-but-kept worktrees,
/// and stray leftovers — and frees a name the moment its worktree is deleted.
enum WorktreeNamer {
    /// Pick a free star name in `folder`. Creates nothing on disk — the
    /// caller's `git worktree add` materializes the directory. Two concurrent
    /// creations could race between allocation and the add; git rejects the
    /// second with "already exists", which surfaces through the normal error
    /// path.
    static func allocate(in folder: URL) -> String {
        func taken(_ name: String) -> Bool {
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(name).path
            )
        }
        if let free = starNames.shuffled().first(where: { !taken($0) }) {
            return free
        }
        // Every star in use — implausible for one repo, but suffix rather
        // than fail.
        return uniqueName(base: starNames.randomElement() ?? "star", isTaken: taken)
    }

    /// Allocate the per-repo folder under the worktrees root: slug of the
    /// repo name, disambiguated against other repos' folder names and
    /// anything already on disk (legacy UUID folders, leftovers from
    /// removed repos).
    static func allocateRepoFolder(name: String, existing: Set<String>) -> String {
        uniqueName(base: WorktreeOps.slug(name)) { candidate in
            existing.contains(candidate) || FileManager.default.fileExists(
                atPath: Database.worktreesDirectory.appendingPathComponent(candidate).path
            )
        }
    }

    /// `base` if free, else the first free `base-2`, `base-3`, …
    private static func uniqueName(base: String, isTaken: (String) -> Bool) -> String {
        if !isTaken(base) { return base }
        var n = 2
        while isTaken("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// IAU proper star names, lowercased. Each is ASCII-only and ≤ 9 chars
    /// so the names stay safe (and short) in paths, branch names, and
    /// terminal prompts.
    static let starNames: [String] = [
        "acamar", "achernar", "achird", "acrux", "acubens", "adhafera",
        "adhara", "ain", "aladfar", "albali", "albireo", "alchiba",
        "alcor", "alcyone", "aldebaran", "alderamin", "algedi", "algenib",
        "algieba", "algol", "algorab", "alhena", "alioth", "alkaid",
        "alkes", "almach", "alnair", "alnasl", "alnilam", "alnitak",
        "alphard", "alphecca", "alpheratz", "alsafi", "alshain", "altair",
        "alterf", "aludra", "alula", "alya", "ancha", "ankaa",
        "antares", "arcturus", "arkab", "ascella", "asellus", "asterope",
        "athebyne", "atik", "atlas", "atria", "avior", "azha",
        "baham", "baten", "beid", "bellatrix", "botein", "brachium",
        "canopus", "capella", "caph", "castor", "cebalrai", "celaeno",
        "chara", "chertan", "cursa", "dabih", "deneb", "denebola",
        "diadem", "diphda", "dschubba", "dubhe", "edasich", "electra",
        "elnath", "eltanin", "enif", "errai", "fawaris", "fomalhaut",
        "furud", "gacrux", "gienah", "gomeisa", "grumium", "hadar",
        "hamal", "hassaleh", "heze", "homam", "izar", "jabbah",
        "kang", "kaus", "keid", "khambalia", "kitalpha", "kochab",
        "kraz", "kurhah", "lesath", "maia", "marfik", "markab",
        "matar", "mebsuta", "megrez", "meissa", "mekbuda", "menkar",
        "menkent", "merak", "merga", "merope", "mesarthim", "mimosa",
        "minkar", "mintaka", "mira", "mirach", "miram", "mirfak",
        "mirzam", "mizar", "mothallah", "muliphein", "muphrid", "muscida",
        "naos", "nashira", "nekkar", "nembus", "nihal", "nunki",
        "nusakan", "okab", "phact", "phecda", "pherkad", "polaris",
        "pollux", "porrima", "procyon", "propus", "rana", "rasalas",
        "rastaban", "regulus", "rigel", "rotanev", "ruchbah", "rukbat",
        "sabik", "sadr", "saiph", "salm", "sargas", "sarin",
        "sceptrum", "schedar", "seginus", "sham", "shaula", "sheliak",
        "sheratan", "sirius", "situla", "skat", "spica", "subra",
        "suhail", "sulafat", "syrma", "tarazed", "taygeta", "tejat",
        "thuban", "toliman", "tureis", "vega", "wasat", "wazn",
        "wezen", "yildun", "zaniah", "zaurak", "zavijava", "zibal",
        "zosma",
    ]
}
