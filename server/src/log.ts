/**
 * Tiny structured logger. JSON to stdout so log aggregators can parse.
 * Avoids pulling a heavyweight dep for the prototype.
 */
type Level = "debug" | "info" | "warn" | "error";

function emit(level: Level, msg: string, fields?: Record<string, unknown>): void {
  const line = JSON.stringify({ t: new Date().toISOString(), level, msg, ...(fields ?? {}) });
  if (level === "error") console.error(line);
  else console.log(line);
}

export const log = {
  debug: (msg: string, fields?: Record<string, unknown>): void => emit("debug", msg, fields),
  info: (msg: string, fields?: Record<string, unknown>): void => emit("info", msg, fields),
  warn: (msg: string, fields?: Record<string, unknown>): void => emit("warn", msg, fields),
  error: (msg: string, fields?: Record<string, unknown>): void => emit("error", msg, fields),
};
