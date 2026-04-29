import { createStore } from "solid-js/store";

export interface AppState {
  streaming: boolean;
  searching: string;
  waiting: boolean;
  busy: boolean;
  streamBuffer: string;
}

export const [state, setState] = createStore<AppState>({
  streaming: false,
  searching: "",
  waiting: false,
  busy: false,
  streamBuffer: "",
});
