import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });
const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });

export const metadata: Metadata = {
  title: "Workflow Arena 工作流评测",
  description: "五种 Superpowers 机制的十五条轨迹，以及 Luna 五工作流、八任务、120 条运行横评。",
  icons: { icon: "/favicon.svg", shortcut: "/favicon.svg" },
  openGraph: {
    title: "Workflow Arena · mechanisms and multi-task workflows",
    description: "15 条机制阶梯轨迹，加上 5 workflows × 8 tasks × 3 的 Luna 多任务横评。",
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
