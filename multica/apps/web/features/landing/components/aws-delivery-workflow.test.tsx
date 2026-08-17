import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AwsDeliveryWorkflow } from "./aws-delivery-workflow";

function mockPrefersReducedMotion(matches: boolean) {
  Object.defineProperty(window, "matchMedia", {
    writable: true,
    configurable: true,
    value: (query: string) => ({
      matches: query.includes("prefers-reduced-motion") ? matches : false,
      media: query,
      onchange: null,
      addListener: () => {},
      removeListener: () => {},
      addEventListener: () => {},
      removeEventListener: () => {},
      dispatchEvent: () => false,
    }),
  });
}

describe("AwsDeliveryWorkflow", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("starts and advances the replay when reduced motion is not requested", () => {
    mockPrefersReducedMotion(false);
    render(<AwsDeliveryWorkflow />);

    expect(screen.getByRole("button", { name: "暂停回放" })).toHaveAttribute(
      "aria-pressed",
      "true",
    );
    expect(
      screen.getByRole("heading", { name: "提出 AWS 部署案例" }),
    ).toBeInTheDocument();

    act(() => vi.advanceTimersByTime(3200));

    expect(
      screen.getByRole("heading", { name: "将目标拆成四个串行阶段" }),
    ).toBeInTheDocument();
  });

  it("does not autoplay with reduced motion but honors explicit playback", () => {
    mockPrefersReducedMotion(true);
    render(<AwsDeliveryWorkflow />);

    const playButton = screen.getByRole("button", { name: "手动播放" });
    expect(playButton).toHaveAttribute("aria-pressed", "false");

    act(() => vi.advanceTimersByTime(3200));
    expect(
      screen.getByRole("heading", { name: "提出 AWS 部署案例" }),
    ).toBeInTheDocument();

    fireEvent.click(playButton);
    expect(screen.getByRole("button", { name: "暂停回放" })).toHaveAttribute(
      "aria-pressed",
      "true",
    );

    act(() => vi.advanceTimersByTime(3200));
    expect(
      screen.getByRole("heading", { name: "将目标拆成四个串行阶段" }),
    ).toBeInTheDocument();
  });

  it("selects a timeline node and pauses automatic playback", () => {
    mockPrefersReducedMotion(false);
    render(<AwsDeliveryWorkflow />);

    fireEvent.click(
      screen.getByRole("button", {
        name: /08 · 迭代 · 智能体团队.*修订、PR 审查与生产发布/,
      }),
    );

    expect(
      screen.getByRole("heading", { name: "修订、PR 审查与生产发布" }),
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "继续回放" })).toHaveAttribute(
      "aria-pressed",
      "false",
    );

    act(() => vi.advanceTimersByTime(6400));
    expect(
      screen.getByRole("heading", { name: "修订、PR 审查与生产发布" }),
    ).toBeInTheDocument();
  });
});
