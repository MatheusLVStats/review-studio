import "./globals.css";
import type { ReactNode } from "react";

export const metadata = { title: "FishingMeta", description: "Systematic reviews and meta-analyses for your team" };

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
