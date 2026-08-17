import type { Metadata } from "next";
import { LandingFooter } from "@/features/landing/components/landing-footer";
import { LandingHeader } from "@/features/landing/components/landing-header";
import { AwsDeliveryWorkflow } from "@/features/landing/components/aws-delivery-workflow";

export const metadata: Metadata = {
  title: "从研究到上线：人机协作交付回放",
  description:
    "通过一个真实的 AWS EKS + PostgreSQL 部署案例，查看用户与多位智能体如何从研究、设计到生产交付迭代协作。",
  alternates: { canonical: "/workflow" },
  openGraph: {
    title: "从研究到上线：人机协作交付回放",
    description:
      "一个真实案例中的研究、设计、实现、部署与反馈闭环。",
    url: "/workflow",
  },
};

export default function WorkflowPage() {
  return (
    <>
      <div className="sticky top-0 z-40 bg-white">
        <LandingHeader variant="light" />
      </div>
      <main className="bg-white text-[#0a0d12]">
        <AwsDeliveryWorkflow />
      </main>
      <LandingFooter />
    </>
  );
}
