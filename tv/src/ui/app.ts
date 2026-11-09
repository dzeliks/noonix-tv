// what a screen can ask of the app: other screens, playback, a menu
import { Action } from "../keys"
import * as tmdb from "../data/tmdb"
import { Stream } from "../data/sources"

export interface Screen {
    el: HTMLElement
    action(a: Action): boolean
    /** back on top after the screen over it closed */
    shown?(): void
    /** gone for good: timers stop */
    closed?(): void
}

/** a title to play: a movie, or one episode of a show */
export interface PlayReq {
    item: tmdb.Item
    imdb?: string | null
    season?: number
    episode?: number
    episodeTitle?: string
    /** seconds in; undefined: where it was left */
    start?: number
    /** the source picked, and the ones to fall back on after it */
    stream?: Stream
    list?: Stream[]
}

export interface MenuEntry {
    label: string
    icon?: string
    run(): void
}

export interface App {
    open(it: tmdb.Item): void
    /** a page of its own: search, library, settings */
    page(id: string): void
    play(req: PlayReq): void
    sources(req: PlayReq): void
    /** a small list over the screen (ok held) */
    menu(title: string, entries: MenuEntry[]): void
    push(s: Screen, over: boolean): void
    /** closes the top screen */
    pop(): void
    /** a short note at the bottom of the screen */
    toast(text: string): void
}
