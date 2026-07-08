import prisma from './prisma';
import { sendAF, sendADJ, sendSingular } from '../controllers/games.controller';
import { getAxiosAgentForUser, verifyProxyWorking } from '../controllers/proxy.controller';

type SchedEntry =
  | { level: number; interval: number; wait_delta?: number }
  | { token: string; interval: number; wait_delta?: number }
  | [string, string]; // legacy: [id, name]

interface SchedGroupRow {
  id: string;
  userId: string;
  platform: string;
  gameId: string | null;
  gameName: string;
  gamePkg: string | null;
  gameKey: string | null;
  eventsOrder: string;
  intervalMinutes: number;
  gaid: string;
  afUid: string | null;
  status: string;
}

const activeTasks = new Map<string, NodeJS.Timeout>();

function sleep(ms: number, groupId: string): Promise<boolean> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      activeTasks.delete(groupId);
      resolve(true);
    }, ms);
    activeTasks.set(groupId, timer);
  });
}

function cancelTask(groupId: string) {
  const timer = activeTasks.get(groupId);
  if (timer) {
    clearTimeout(timer);
    activeTasks.delete(groupId);
  }
}

export function stopSchedTask(groupId: string) {
  cancelTask(groupId);
}

async function isGroupActive(groupId: string): Promise<boolean> {
  const g = await prisma.schedGroup.findUnique({
    where: { id: groupId },
    select: { status: true },
  });
  return g?.status === 'active';
}

// Helper: Check if user has active subscription
async function hasActiveSubscription(userId: string): Promise<{ active: boolean; subscriptionId?: string }> {
  const now = new Date();
  const sub = await prisma.subscription.findFirst({
    where: { userId, status: 'ACTIVE', endDate: { gt: now } },
    select: { id: true },
  });
  return sub ? { active: true, subscriptionId: sub.id } : { active: false };
}

// Helper: Refund operation back to user
async function refundOperation(userId: string, subscriptionId: string): Promise<void> {
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  try {
    await prisma.dailyUsage.update({
      where: { userId_subscriptionId_date: { userId, subscriptionId, date: today } },
      data: { operationsUsed: { decrement: 1 } },
    });
    console.log(`[sched] Refunded 1 operation to user ${userId}`);
  } catch (err) {
    console.error(`[sched] Failed to refund operation:`, err);
  }
}

async function sendOneEvent(
  platform: string,
  gameKey: string | null,
  gamePkg: string | null,
  gaid: string,
  afUid: string,
  entry: SchedEntry,
  isCustom: boolean,
  agent?: any
): Promise<{ status: number; body: string }> {
  try {
    if (isCustom) {
      if ('token' in entry) {
        const tok = entry.token;
        if (platform === 'adj' && gameKey) {
          return await sendADJ(gameKey, tok, gaid, agent);
        }
        return { status: 0, body: 'token mode requires adj platform' };
      }
      // level mode
      const levelNum = (entry as { level: number }).level;
      if (platform === 'adj' && gameKey) {
        const ev = await prisma.gameEvent.findFirst({
          where: { game: { appToken: gameKey } },
          orderBy: { eventName: 'asc' },
          select: { eventToken: true },
        });
        if (ev?.eventToken) {
          return await sendADJ(gameKey, ev.eventToken, gaid, agent);
        }
        return { status: 0, body: 'no event token found' };
      }
      if (platform === 'singular' && gamePkg && gameKey) {
        const ev = await prisma.gameEvent.findFirst({
          where: { game: { appKey: gameKey } },
          select: { eventName: true },
        });
        const baseName = ev?.eventName ?? 'level_1';
        const customName = baseName.replace(/\d+/, String(levelNum)) || `level_${levelNum}`;
        return await sendSingular(customName, gaid, afUid, gamePkg, gameKey, undefined, agent);
      }
      // af
      if (platform === 'af' && gamePkg && gameKey) {
        const ev = await prisma.gameEvent.findFirst({
          where: { game: { devKey: gameKey }, OR: [{ eventName: { contains: 'level' } }, { eventName: { contains: 'kingdom' } }] },
          select: { eventName: true },
        });
        const baseName = ev?.eventName ?? 'af_level_1_achieved';
        const customName = /\d/.test(baseName)
          ? baseName.replace(/\d+/, String(levelNum))
          : `${baseName}_${levelNum}`;
        return await sendAF(gamePkg, gameKey, gaid, afUid, customName, undefined, agent);
      }
      return { status: 0, body: 'missing game config' };
    }

    // legacy mode: entry = [id, name]
    const [, eventName] = entry as [string, string];
    if (platform === 'af' && gamePkg && gameKey) {
      return await sendAF(gamePkg, gameKey, gaid, afUid, eventName, undefined, agent);
    }
    if (platform === 'singular' && gamePkg && gameKey) {
      return await sendSingular(eventName, gaid, afUid, gamePkg, gameKey, undefined, agent);
    }
    if (platform === 'adj' && gameKey) {
      const ev = await prisma.gameEvent.findFirst({
        where: { eventName },
        select: { eventToken: true },
      });
      if (ev?.eventToken) return await sendADJ(gameKey, ev.eventToken, gaid, agent);
    }
    return { status: 0, body: 'unsupported platform' };
  } catch (err: any) {
    return { status: 0, body: String(err?.message ?? err) };
  }
}

export async function runSchedGroupLoop(groupId: string): Promise<void> {
  const g = await prisma.schedGroup.findUnique({ where: { id: groupId } });
  if (!g || g.status !== 'active') {
    cancelTask(groupId);
    return;
  }

  // Check subscription before starting
  const subCheck = await hasActiveSubscription(g.userId);
  if (!subCheck.active) {
    console.log(`[sched:${groupId}] No active subscription - stopping`);
    await prisma.schedGroup.update({
      where: { id: groupId },
      data: { status: 'stopped' },
    }).catch(() => {});
    cancelTask(groupId);
    return;
  }

  let events: SchedEntry[];
  try {
    events = JSON.parse(g.eventsOrder) as SchedEntry[];
  } catch {
    cancelTask(groupId);
    return;
  }

  const isCustom =
    events.length > 0 &&
    typeof events[0] === 'object' &&
    !Array.isArray(events[0]) &&
    ('level' in (events[0] as object) || 'token' in (events[0] as object));

  if (isCustom) {
    events.sort((a, b) => {
      const ia = (a as { interval: number }).interval;
      const ib = (b as { interval: number }).interval;
      return ia - ib;
    });
    let prev = 0;
    for (const e of events as (typeof events[number] & { wait_delta?: number })[]) {
      const cur = (e as { interval: number }).interval;
      (e as { wait_delta: number }).wait_delta = cur - prev;
      prev = cur;
    }
  }

  const intervalSec = g.intervalMinutes * 60;

  // Resolve the user's selected proxy once at the start of the loop
  let agent: any = null;
  try {
    agent = await getAxiosAgentForUser(g.userId);
    if (agent) {
      const proxyCheck = await verifyProxyWorking(g.userId);
      if (!proxyCheck.working) {
        console.log(`[sched:${groupId}] proxy not working — aborting: ${proxyCheck.error}`);
        // Refund remaining operations since proxy failed and we can't continue
        const remaining = events.length;
        if (subCheck.subscriptionId) {
          for (let r = 0; r < remaining; r++) {
            await refundOperation(g.userId, subCheck.subscriptionId);
          }
        }
        await prisma.schedGroup.update({
          where: { id: groupId },
          data: { status: 'stopped' },
        }).catch(() => {});
        cancelTask(groupId);
        return;
      }
    }
  } catch (err) {
    console.warn(`[sched:${groupId}] proxy resolve error:`, err);
  }

  for (let i = 0; i < events.length; i++) {
    // Check subscription and group status before each event
    if (!(await isGroupActive(groupId))) {
      cancelTask(groupId);
      return;
    }

    // Re-check subscription before each event
    const currentSub = await hasActiveSubscription(g.userId);
    if (!currentSub.active) {
      console.log(`[sched:${groupId}] Subscription expired during execution - stopping`);
      // Refund remaining operations
      const remaining = events.length - i;
      if (subCheck.subscriptionId) {
        for (let r = 0; r < remaining; r++) {
          await refundOperation(g.userId, subCheck.subscriptionId);
        }
      }
      await prisma.schedGroup.update({
        where: { id: groupId },
        data: { status: 'stopped' },
      }).catch(() => {});
      cancelTask(groupId);
      return;
    }

    let waitMin = 0;
    if (isCustom) {
      const e = events[i] as { wait_delta?: number; interval: number };
      waitMin = e.wait_delta ?? e.interval;
    } else if (i > 0 && intervalSec > 0) {
      waitMin = g.intervalMinutes;
    }

    if (waitMin > 0) {
      const ok = await sleep(waitMin * 60 * 1000, groupId);
      if (!ok || !(await isGroupActive(groupId))) {
        cancelTask(groupId);
        return;
      }
    } else if (i > 0 && !isCustom) {
      await sleep(500, groupId);
    }

    const entry = events[i];
    const label = isCustom
      ? ('token' in (entry as object)
          ? `TOKEN:${(entry as { token: string }).token}`
          : `LV${(entry as { level: number }).level}`)
      : (entry as [string, string])[1];

    const { status } = await sendOneEvent(
      g.platform,
      g.gameKey,
      g.gamePkg,
      g.gaid,
      g.afUid ?? '',
      entry,
      isCustom,
      agent ?? undefined
    );

    // If send failed, refund the operation
    const sendFailed = status < 200 || status >= 300;
    if (sendFailed && subCheck.subscriptionId) {
      await refundOperation(g.userId, subCheck.subscriptionId);
      console.log(`[sched:${groupId}] Event failed (HTTP ${status}) - refunded 1 operation`);
    }

    await prisma.schedGroup.update({
      where: { id: groupId },
      data: { nextRun: new Date() },
    }).catch(() => {});

    console.log(`[sched:${groupId}] ${g.gameName} | ${label} | HTTP ${status}${sendFailed ? ' [REFUNDED]' : ''}`);
  }

  await prisma.schedGroup.update({
    where: { id: groupId },
    data: { status: 'completed' },
  }).catch(() => {});
  cancelTask(groupId);
}

export function startSchedTask(groupId: string): void {
  if (activeTasks.has(groupId)) return;
  runSchedGroupLoop(groupId).catch((err) => {
    console.error(`[sched] group ${groupId} failed:`, err);
    activeTasks.delete(groupId);
  });
}

export async function resumeActiveGroups(): Promise<void> {
  try {
    const groups = await prisma.schedGroup.findMany({
      where: { status: 'active' },
      select: { id: true, userId: true },
    });
    for (const g of groups) {
      // Check if user still has active subscription before resuming
      const subCheck = await hasActiveSubscription(g.userId);
      if (subCheck.active) {
        startSchedTask(g.id);
      } else {
        // Stop the group if subscription expired
        await prisma.schedGroup.update({
          where: { id: g.id },
          data: { status: 'stopped' },
        }).catch(() => {});
        console.log(`[sched] Stopped group ${g.id} - subscription expired`);
      }
    }
    if (groups.length > 0) {
      console.log(`✅ Resumed ${groups.length} active scheduling group(s)`);
    }
  } catch (err) {
    console.error('[sched] resume error:', err);
  }
}

// Cancel expired subscriptions and stop their scheduling groups
export async function cancelExpiredSubscriptions(): Promise<void> {
  try {
    const now = new Date();

    // Find all expired but still ACTIVE subscriptions
    const expiredSubs = await prisma.subscription.findMany({
      where: {
        status: 'ACTIVE',
        endDate: { lte: now },
      },
      select: { id: true, userId: true },
    });

    if (expiredSubs.length === 0) return;

    // Cancel each expired subscription
    for (const sub of expiredSubs) {
      await prisma.subscription.update({
        where: { id: sub.id },
        data: { status: 'EXPIRED' },
      });

      // Stop all active scheduling groups for this user
      const activeGroups = await prisma.schedGroup.findMany({
        where: { userId: sub.userId, status: 'active' },
        select: { id: true },
      });

      for (const g of activeGroups) {
        stopSchedTask(g.id);
        await prisma.schedGroup.update({
          where: { id: g.id },
          data: { status: 'stopped' },
        }).catch(() => {});
      }

      console.log(`[subscription] Expired subscription ${sub.id} for user ${sub.userId} - stopped ${activeGroups.length} scheduling groups`);
    }

    console.log(`✅ Processed ${expiredSubs.length} expired subscription(s)`);
  } catch (err) {
    console.error('[subscription] cancelExpired error:', err);
  }
}
