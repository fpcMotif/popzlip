export type ActionKind =
  | "copy"
  | "cut"
  | "paste"
  | "search"
  | "open_url"
  | "email"
  | "dictionary"
  | "calculate"
  | "upper_case"
  | "lower_case"
  | "title_case"
  | "markdown_bold"
  | "markdown_italic"
  | "markdown_code"
  | "markdown_quote"
  | "word_count"
  | "terminal"
  | "append_clipboard"
  | "notes";

export interface Action {
  id: string;
  label: string;
  kind: ActionKind;
  payload: string;
}

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface ScreenBounds {
  width: number;
  height: number;
  menuBarHeight: number;
  margin: number;
}

export interface Placement {
  x: number;
  y: number;
  width: number;
  height: number;
  arrowBelow: boolean;
}

export interface TextStats {
  words: number;
  chars: number;
  lines: number;
}

export interface YamlExtension {
  name: string;
  icon: string;
  url: string;
  shellScript: string;
  keyCombo: string;
}
