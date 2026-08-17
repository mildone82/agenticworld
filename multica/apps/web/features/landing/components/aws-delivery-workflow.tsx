"use client";

import { useEffect, useState } from "react";
import {
  Bot,
  CheckCircle2,
  ChevronLeft,
  ChevronRight,
  Cloud,
  GitPullRequest,
  MessageSquare,
  Pause,
  Play,
  UserRound,
} from "lucide-react";
import { cn } from "@multica/ui/lib/utils";

const events = [
  {
    phase: "发起",
    actor: "用户",
    actorDetail: "明确真实目标与验收方向",
    title: "提出 AWS 部署案例",
    summary: "提出将系统部署到 AWS（EKS + PostgreSQL）的可行性研究，并要求在结论确认后进入设计、实现和运维落地。",
    outcome: "一个可追踪的真实交付目标被创建。",
    kind: "user",
  },
  {
    phase: "编排",
    actor: "协调智能体",
    actorDetail: "拆解与路由工作",
    title: "将目标拆成四个串行阶段",
    summary: "把研究、系统设计、部署工件实现和 AWS 运维部署串联为阶段化任务；每一阶段完成后才推进下一阶段。",
    outcome: "复杂请求被转换为可分配、可验收的工作流。",
    kind: "agent",
  },
  {
    phase: "研究",
    actor: "研究智能体",
    actorDetail: "收集事实并校正假设",
    title: "验证现有栈与 AWS 可行性",
    summary: "通过 Gate 0 核实实际架构为 Next.js、Go、PostgreSQL 与 Redis，并撤回与代码不符的 SQS / Outbox / worker 假设。",
    outcome: "后续设计建立在经验证的系统事实之上。",
    kind: "research",
  },
  {
    phase: "设计",
    actor: "系统架构师",
    actorDetail: "将事实沉淀为部署设计",
    title: "修正设计并定义 EKS 目标架构",
    summary: "依据真实组件边界重写设计：Web、API、PostgreSQL、运行时连接和 Helm 部署路径均有明确职责。",
    outcome: "设计不再依赖被推翻的前提。",
    kind: "agent",
  },
  {
    phase: "实现",
    actor: "软件工程师",
    actorDetail: "把设计变成可审查的工件",
    title: "交付容器、Helm 与部署配置",
    summary: "将设计落实为 Docker、Kubernetes / Helm 配置、部署文档与验证脚本，形成可复现的交付物。",
    outcome: "代码与基础设施配置进入可审查状态。",
    kind: "build",
  },
  {
    phase: "部署",
    actor: "运维专家",
    actorDetail: "在真实 AWS 环境验证",
    title: "部署到 EKS 并验证服务连通",
    summary: "把工件部署到 EKS，验证入口、服务、数据层以及运行时通信；结果和证据回写到同一个议题。",
    outcome: "从“方案可行”转为可访问的生产系统。",
    kind: "cloud",
  },
  {
    phase: "反馈",
    actor: "用户",
    actorDetail: "在实际界面中验收并提出调整",
    title: "基于结果继续迭代",
    summary: "用户查看部署结果后，持续提出文档、运行时、访问控制和界面能力等反馈，而不是把上线视为终点。",
    outcome: "真实使用反馈回到任务系统，形成下一轮需求。",
    kind: "user",
  },
  {
    phase: "迭代",
    actor: "智能体团队",
    actorDetail: "实现、审查、发布",
    title: "修订、PR 审查与生产发布",
    summary: "团队根据反馈完成修改并通过 PR 审查；最终变更合并，生产部署完成。",
    outcome: "已合并 PR #6；生产部署状态记录为 revision 5。",
    kind: "review",
  },
] as const;

type EventKind = (typeof events)[number]["kind"];

function ActorIcon({ kind }: { kind: EventKind }) {
  const className = "size-4";
  if (kind === "user") return <UserRound className={className} aria-hidden />;
  if (kind === "cloud") return <Cloud className={className} aria-hidden />;
  if (kind === "review") return <GitPullRequest className={className} aria-hidden />;
  if (kind === "research") return <MessageSquare className={className} aria-hidden />;
  return <Bot className={className} aria-hidden />;
}

const accentClassByKind: Record<EventKind, string> = {
  user: "bg-amber-400 text-amber-950",
  agent: "bg-violet-500 text-white",
  research: "bg-sky-500 text-white",
  build: "bg-emerald-500 text-emerald-950",
  cloud: "bg-indigo-500 text-white",
  review: "bg-rose-500 text-white",
};

export function AwsDeliveryWorkflow() {
  const [activeIndex, setActiveIndex] = useState(0);
  const [isPlaying, setIsPlaying] = useState(false);
  const [prefersReducedMotion, setPrefersReducedMotion] = useState(true);
  const activeEvent = events[activeIndex]!;

  useEffect(() => {
    const media = window.matchMedia("(prefers-reduced-motion: reduce)");
    const updatePreference = () => {
      setPrefersReducedMotion(media.matches);
      setIsPlaying(!media.matches);
    };

    updatePreference();
    media.addEventListener("change", updatePreference);
    return () => media.removeEventListener("change", updatePreference);
  }, []);

  useEffect(() => {
    if (!isPlaying) return;
    const timer = window.setInterval(() => {
      setActiveIndex((current) => (current + 1) % events.length);
    }, 3200);
    return () => window.clearInterval(timer);
  }, [isPlaying]);

  function selectEvent(index: number) {
    setActiveIndex(index);
    setIsPlaying(false);
  }

  function goToOffset(offset: number) {
    selectEvent((activeIndex + offset + events.length) % events.length);
  }

  return (
    <section className="overflow-hidden">
      <div className="border-b border-[#0a0d12]/10 bg-[#f6f7fb]">
        <div className="mx-auto max-w-[1180px] px-4 py-16 sm:px-6 sm:py-20 lg:px-8">
          <p className="text-micro font-semibold uppercase tracking-[0.16em] text-[#59616d]">
            真实案例回放 · AWS EKS + PostgreSQL
          </p>
          <h1 className="mt-4 max-w-[850px] landing-serif text-[3rem] leading-[1.02] tracking-[-0.035em] sm:text-[4rem] lg:text-[5rem]">
            从研究到生产上线，
            <span className="text-[#687283]">人和智能体如何共同交付。</span>
          </h1>
          <p className="mt-7 max-w-[710px] text-body-lg leading-8 text-[#505966] sm:text-title">
            这不是理想流程图，而是一次实际部署工作中的协作轨迹：用户提出目标，智能体分阶段研究、设计、实现和部署，用户再以真实结果驱动下一轮改进。
          </p>
          <div className="mt-9 flex flex-wrap gap-3 text-label text-[#4b5563]">
            {["4 个串行阶段", "多角色协作", "真实反馈闭环", "PR 审查后生产发布"].map(
              (label) => (
                <span key={label} className="rounded-full border border-[#0a0d12]/12 bg-white px-3.5 py-2">
                  {label}
                </span>
              ),
            )}
          </div>
        </div>
      </div>

      <div className="mx-auto max-w-[1180px] px-4 py-14 sm:px-6 sm:py-20 lg:px-8">
        <div className="mb-7 flex flex-wrap items-center justify-between gap-4">
          <div>
            <p className="text-micro font-semibold uppercase tracking-[0.15em] text-[#59616d]">
              交互回放
            </p>
            <p className="mt-1 text-body text-[#505966]">
              选择任一节点，或自动播放这次交付如何不断获得反馈与推进。
            </p>
          </div>
          <button
            type="button"
            onClick={() => setIsPlaying((playing) => !playing)}
            aria-pressed={isPlaying}
            className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-[#0a0d12] px-4 text-label font-semibold text-white transition-colors hover:bg-[#0a0d12]/85 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#0a0d12]"
          >
            {isPlaying ? <Pause className="size-4" aria-hidden /> : <Play className="size-4" aria-hidden />}
            {isPlaying ? "暂停回放" : prefersReducedMotion ? "手动播放" : "继续回放"}
          </button>
        </div>

        <div className="grid gap-8 lg:grid-cols-[minmax(0,0.9fr)_minmax(360px,1.1fr)] lg:gap-14">
          <ol aria-label="案例交付时间线" className="relative space-y-1 border-l border-[#0a0d12]/12 pl-5 sm:pl-7">
            {events.map((event, index) => {
              const isActive = index === activeIndex;
              return (
                <li key={event.title} className="relative">
                  <span
                    aria-hidden
                    className={cn(
                      "absolute -left-[29px] top-5 size-3 rounded-full border-2 border-white sm:-left-[37px]",
                      isActive ? "bg-[#0a0d12] ring-4 ring-[#0a0d12]/10" : "bg-[#d6d9df]",
                    )}
                  />
                  <button
                    type="button"
                    onClick={() => selectEvent(index)}
                    aria-current={isActive ? "step" : undefined}
                    className={cn(
                      "group flex w-full items-start gap-4 rounded-2xl px-4 py-4 text-left transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#0a0d12]",
                      isActive ? "bg-[#0a0d12] text-white shadow-[0_12px_30px_rgba(10,13,18,0.13)]" : "hover:bg-[#0a0d12]/[0.045]",
                    )}
                  >
                    <span
                      className={cn(
                        "mt-0.5 inline-flex size-8 shrink-0 items-center justify-center rounded-lg",
                        isActive ? accentClassByKind[event.kind] : "bg-[#0a0d12]/[0.06] text-[#59616d]",
                      )}
                    >
                      <ActorIcon kind={event.kind} />
                    </span>
                    <span className="min-w-0">
                      <span className={cn("block text-caption font-medium", isActive ? "text-[#b4bac4]" : "text-[#59616d]")}>
                        {String(index + 1).padStart(2, "0")} · {event.phase} · {event.actor}
                      </span>
                      <span className="mt-1 block text-body font-semibold leading-snug">{event.title}</span>
                    </span>
                  </button>
                </li>
              );
            })}
          </ol>

          <article aria-live="polite" className="relative overflow-hidden rounded-[24px] border border-[#0a0d12]/10 bg-[#0a0d12] p-6 text-white shadow-[0_20px_60px_rgba(10,13,18,0.15)] sm:p-9">
            <div aria-hidden className="absolute -right-24 -top-24 size-64 rounded-full bg-violet-500/25 blur-3xl" />
            <div aria-hidden className="absolute -bottom-32 -left-24 size-64 rounded-full bg-sky-400/15 blur-3xl" />
            <div className="relative">
              <div className="flex items-center justify-between gap-4">
                <span className="rounded-full border border-white/15 bg-white/8 px-3 py-1.5 text-caption font-medium text-[#c3c7ce]">
                  第 {activeIndex + 1} / {events.length} 步
                </span>
                <span className="inline-flex items-center gap-2 text-caption text-[#b4bac4]">
                  <span className="relative flex size-2.5">
                    {isPlaying ? <span className="absolute inline-flex size-full animate-ping rounded-full bg-emerald-300 opacity-70 motion-reduce:hidden" /> : null}
                    <span className="relative inline-flex size-2.5 rounded-full bg-emerald-300" />
                  </span>
                  {isPlaying ? "回放中" : "已暂停"}
                </span>
              </div>

              <div className="mt-9 flex items-center gap-3">
                <span className={cn("inline-flex size-11 items-center justify-center rounded-xl", accentClassByKind[activeEvent.kind])}>
                  <ActorIcon kind={activeEvent.kind} />
                </span>
                <div>
                  <p className="text-label font-semibold">{activeEvent.actor}</p>
                  <p className="text-caption text-[#b4bac4]">{activeEvent.actorDetail}</p>
                </div>
              </div>

              <h2 className="mt-8 landing-serif text-[2.4rem] leading-[1.05] tracking-[-0.025em] sm:text-[3rem]">
                {activeEvent.title}
              </h2>
              <p className="mt-5 text-body-lg leading-8 text-[#c3c7ce]">{activeEvent.summary}</p>

              <div className="mt-8 rounded-2xl border border-white/12 bg-white/[0.06] p-5">
                <p className="text-micro font-semibold uppercase tracking-[0.14em] text-[#aab0ba]">这个节点带来的结果</p>
                <p className="mt-2 flex gap-2 text-body font-medium leading-7 text-[#e4e7eb]">
                  <CheckCircle2 className="mt-1 size-4 shrink-0 text-emerald-300" aria-hidden />
                  {activeEvent.outcome}
                </p>
              </div>

              <div className="mt-9 flex items-center justify-between gap-3">
                <button
                  type="button"
                  onClick={() => goToOffset(-1)}
                  className="inline-flex min-h-11 items-center gap-2 rounded-xl border border-white/16 px-3.5 text-label font-semibold text-white transition-colors hover:bg-white/10 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-white"
                >
                  <ChevronLeft className="size-4" aria-hidden />
                  上一步
                </button>
                <button
                  type="button"
                  onClick={() => goToOffset(1)}
                  className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-white px-3.5 text-label font-semibold text-[#0a0d12] transition-colors hover:bg-white/88 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-white"
                >
                  下一步
                  <ChevronRight className="size-4" aria-hidden />
                </button>
              </div>
            </div>
          </article>
        </div>

        <div className="mt-14 rounded-2xl border border-[#0a0d12]/10 bg-[#f7f8fa] p-6 sm:p-8">
          <p className="text-micro font-semibold uppercase tracking-[0.15em] text-[#59616d]">为什么这个过程可控</p>
          <div className="mt-5 grid gap-5 sm:grid-cols-3">
            <div>
              <h2 className="text-title-sm font-semibold">任务是可见的</h2>
              <p className="mt-2 text-body leading-7 text-[#505966]">阶段、指派、状态、产物和评论都落在同一个工作流内，不依赖口头同步。</p>
            </div>
            <div>
              <h2 className="text-title-sm font-semibold">结论能被校正</h2>
              <p className="mt-2 text-body leading-7 text-[#505966]">研究先核验真实系统，再让架构和实现建立在可靠事实之上，而非沿用错误假设。</p>
            </div>
            <div>
              <h2 className="text-title-sm font-semibold">上线不是终点</h2>
              <p className="mt-2 text-body leading-7 text-[#505966]">用户在生产结果上继续反馈，智能体团队再进入修改、审查和发布的下一轮闭环。</p>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
