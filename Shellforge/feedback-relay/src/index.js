import { handle } from "./handler.js";

export default {
  fetch: (request, env) => handle(request, env, { fetch: (u, i) => fetch(u, i), now: Date.now }),
};
