// profiles (core profiles, cut down): each has its own progress, list and trakt sign-in on this tv
import * as store from "./store"

export interface Profile { id: number; name: string; color: string }

// the qt app's avatar colours
export const colors = ["#ef6f9b", "#6fa8ef", "#8fe3a5", "#f2c14e", "#b48cf2", "#f28c5a"]

const own = ["progress", "watched", "library", "trakt"]

export function list(): Profile[] {
    const l = store.get<Profile[] | null>("profiles", null)
    if (l && l.length) return l
    // the first run: one profile, holding what was kept before profiles came
    const first: Profile = { id: 1, name: "", color: colors[0] }
    own.forEach(function (k) {
        const v = store.get<unknown>(k, null)
        if (v !== null) { store.set("p1:" + k, v); store.remove(k) }
    })
    store.set("profiles", [first])
    return [first]
}

export function current(): Profile {
    const l = list()
    const id = store.get<number>("profile", l[0].id)
    return l.filter(function (p) { return p.id === id })[0] || l[0]
}

/** a key of the current profile's own */
export function key(k: string): string { return "p" + current().id + ":" + k }

export function use(id: number): void { store.set("profile", id) }

export function add(name: string): Profile {
    const l = list()
    const id = l.reduce(function (m, p) { return Math.max(m, p.id) }, 0) + 1
    const p: Profile = { id: id, name: name, color: colors[(id - 1) % colors.length] }
    l.push(p)
    store.set("profiles", l)
    return p
}

export function rename(id: number, name: string): void {
    store.set("profiles", list().map(function (p) { if (p.id === id) p.name = name; return p }))
}

/** the last one stays */
export function remove(id: number): void {
    const l = list()
    if (l.length < 2) return
    store.set("profiles", l.filter(function (p) { return p.id !== id }))
    own.forEach(function (k) { store.remove("p" + id + ":" + k) })
    if (current().id === id) use(list()[0].id)
}
