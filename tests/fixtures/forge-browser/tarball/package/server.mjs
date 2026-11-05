import { Hub } from './lib/hub.mjs';

const MODE = process.env.JBC_MODE || 'browser';
const COMMON = '- browser_snapshot lists the page.';
const INSTRUCTIONS = MODE === 'browser'
  ? `These tools drive a Chrome window that this server opens. The first tool call opens it. Sign in once in that window.\n${COMMON}\n- browser_record saves a recording.`
  : `These tools control the user's own Chrome browser.\n${COMMON}`;

await new Hub(INSTRUCTIONS).start();
