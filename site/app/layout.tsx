import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });
const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });

export const metadata: Metadata = {
  title: "Workflow Arena 五种方法轨迹对比",
  description: "Without、Slim、Requirement Loop、Review Loops 与 Full 的十五条轨迹、阶段、墙钟和 token 分布。",
  icons: { icon: "/favicon.svg", shortcut: "/favicon.svg" },
  openGraph: {
    title: "Workflow Arena · 5 methods · 15 runs",
    description: "十五条 native Codex rollout：Without、Slim、Requirement Loop、Review Loops、Full。",
    images: [{ url: "/og.png", width: 1730, height: 909 }],
  },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="zh-CN">
      <body className={`${geistSans.variable} ${geistMono.variable}`}>{children}</body>
    </html>
  );
}
