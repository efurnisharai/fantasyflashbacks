import FantasyFootballDraft from "./FantasyFootballDraft";
import { Analytics } from "@vercel/analytics/react";
import { SpeedInsights } from "@vercel/speed-insights/react";

export default function App() {
  return (
    <>
      <FantasyFootballDraft />
      <Analytics />
      <SpeedInsights />
    </>
  );
}