// what the app keeps: settings and profiles in localStorage, and a cache of api answers (memory first,
// localStorage behind it, the oldest let go when the tv's storage is full)

const prefix = "noonix:"
const cachePrefix = "noonix-cache:"

function now(): number { return Math.floor(Date.now() / 1000) }

export function get<T>(key: string, fallback: T): T {
    try {
        const raw = localStorage.getItem(prefix + key)
        return raw === null ? fallback : JSON.parse(raw) as T
    } catch (e) {
        return fallback
    }
}

export function set(key: string, value: unknown): void {
    write(prefix + key, JSON.stringify(value))
}

export function remove(key: string): void {
    try { localStorage.removeItem(prefix + key) } catch (e) { /* storage off */ }
}

/** a write; a full storage lets go of the older half of the cache and tries once more */
function write(key: string, text: string): boolean {
    try {
        localStorage.setItem(key, text)
        return true
    } catch (e) {
        evict(0.5)
        try {
            localStorage.setItem(key, text)
            return true
        } catch (e2) {
            console.warn("store: full, " + key + " not kept")
            return false
        }
    }
}

// ---- the cache: { at, ttl, v }

interface Entry { at: number; ttl: number; v: unknown }

const memory: { [key: string]: Entry } = {}

function read(key: string): Entry | null {
    const m = memory[key]
    if (m) return m
    try {
        const raw = localStorage.getItem(cachePrefix + key)
        if (!raw) return null
        const e = JSON.parse(raw) as Entry
        memory[key] = e
        return e
    } catch (e) {
        return null
    }
}

export function cacheGet<T>(key: string, stale?: boolean): T | null {
    const e = read(key)
    if (!e) return null
    if (!stale && now() - e.at > e.ttl) return null
    return e.v as T
}

export function cachePut(key: string, v: unknown, ttl: number): void {
    const e = { at: now(), ttl, v }
    memory[key] = e
    write(cachePrefix + key, JSON.stringify(e))
}

/** lets go of a share of the cache, oldest first */
export function evict(share: number): void {
    const keys: { k: string; at: number }[] = []
    try {
        for (let i = 0; i < localStorage.length; i++) {
            const k = localStorage.key(i)
            if (!k || k.indexOf(cachePrefix) !== 0) continue
            let at = 0
            try { at = (JSON.parse(localStorage.getItem(k) || "{}") as Entry).at || 0 } catch (e) { /* broken: goes first */ }
            keys.push({ k, at })
        }
        keys.sort(function (a, b) { return a.at - b.at })
        const n = Math.ceil(keys.length * share)
        for (let i = 0; i < n; i++) {
            localStorage.removeItem(keys[i].k)
            delete memory[keys[i].k.slice(cachePrefix.length)]
        }
    } catch (e) { /* storage off */ }
}

/** a fresh copy, else the network (kept for ttl seconds), else a stale copy when offline */
export function cached<T>(key: string, ttl: number, load: () => Promise<T>): Promise<T> {
    const hit = cacheGet<T>(key)
    if (hit !== null) return Promise.resolve(hit)
    return load().then(function (v) {
        cachePut(key, v, ttl)
        return v
    }, function (e: { status?: number }) {
        const old = e && e.status === 404 ? null : cacheGet<T>(key, true)
        if (old !== null) {
            console.warn("store: stale copy of " + key)
            return old
        }
        throw e
    })
}
