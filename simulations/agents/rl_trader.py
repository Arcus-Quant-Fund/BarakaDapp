"""
Baraka Protocol — Reinforcement Learning Trader Agent

Trains a PPO agent (Stable Baselines 3) to learn optimal trading strategies
within the Baraka Protocol constraints:
  - Leverage hard-capped at 5x (ShariahGuard)
  - Funding rate is ι=0 (no interest floor — affects carry cost)
  - Liquidation at 2% maintenance margin

The agent learns:
  1. WHEN to enter long/short positions
  2. WHAT leverage to use (1–5x)
  3. WHEN to exit before getting liquidated
  4. HOW to exploit funding rate mispricings

Usage:
    python simulations/agents/rl_trader.py --train
    python simulations/agents/rl_trader.py --eval --model results/rl_trader.zip
"""

import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import argparse
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

import gymnasium as gym
from gymnasium import spaces

from config.params import (
    INITIAL_BTC_PRICE, PRICE_VOLATILITY, MAX_LEVERAGE,
    MAINTENANCE_MARGIN_RATE, LIQUIDATION_PENALTY,
    MAX_FUNDING_RATE, MIN_FUNDING_RATE,
)


# ─── Environment ──────────────────────────────────────────────────────────────

class BarakaTraderEnv(gym.Env):
    """
    Gymnasium environment modelling a single trader interacting with Baraka Protocol.

    Observation space (8 features):
        0. mark_price (normalised to initial price)
        1. index_price (normalised)
        2. funding_rate (in [-0.0075, +0.0075])
        3. cumulative_funding_index
        4. current position: size (0 if flat)
        5. current position: collateral (0 if flat)
        6. current position: is_long (0/1, 0 if flat)
        7. free collateral (normalised)

    Action space (Discrete 12):
        0     = Hold / do nothing
        1–5   = Open long, leverage 1x–5x  (uses 10% of free collateral)
        6–10  = Open short, leverage 1x–5x
        11    = Close current position

    Reward:
        realised PnL on close, minus funding paid, minus liquidation penalty.
        Shaped with a small survival reward each step to discourage holding losers.
    """

    metadata = {"render_modes": []}

    def __init__(self, n_steps: int = 720, seed: int = 0):
        super().__init__()
        self.n_steps   = n_steps
        self._seed     = seed
        self.rng       = np.random.default_rng(seed)

        self.observation_space = spaces.Box(
            low  = np.array([-np.inf] * 8, dtype=np.float32),
            high = np.array([ np.inf] * 8, dtype=np.float32),
        )
        self.action_space = spaces.Discrete(12)
        self.reset()

    def reset(self, seed=None, options=None):
        super().reset(seed=seed)
        if seed is not None:
            self.rng = np.random.default_rng(seed)

        self.step_count         = 0
        self.mark_price         = INITIAL_BTC_PRICE
        self.index_price        = INITIAL_BTC_PRICE
        self.funding_rate       = 0.0
        self.cum_funding        = 0.0      # additive

        # Position state
        self.in_position        = False
        self.pos_size           = 0.0
        self.pos_collateral     = 0.0
        self.pos_is_long        = False
        self.pos_entry_price    = 0.0
        self.pos_cum_at_entry   = 0.0

        # Wallet
        self.free_collateral    = 50_000.0  # $50k starting capital
        self.total_pnl          = 0.0
        self.episode_reward     = 0.0

        return self._obs(), {}

    # ── Step ──────────────────────────────────────────────────────────────────

    def step(self, action):
        self.step_count += 1

        # 1. Update oracle prices
        shock_i = self.rng.normal(0, PRICE_VOLATILITY)
        shock_m = self.rng.normal(0, PRICE_VOLATILITY * 0.7)
        self.index_price = self.index_price * np.exp(shock_i)
        # mark mean-reverts to index
        self.mark_price  = self.mark_price * np.exp(shock_m) * 0.9 + self.index_price * 0.1

        # 2. Compute funding rate (ι=0)
        raw_rate    = (self.mark_price - self.index_price) / self.index_price
        self.funding_rate = float(np.clip(raw_rate, MIN_FUNDING_RATE, MAX_FUNDING_RATE))
        self.cum_funding += self.funding_rate

        # 3. Accrue funding to open position
        funding_pnl = 0.0
        if self.in_position:
            delta = self.cum_funding - self.pos_cum_at_entry
            if self.pos_is_long:
                funding_pnl  = -delta * self.pos_size
                self.pos_collateral += funding_pnl
            else:
                funding_pnl  = +delta * self.pos_size
                self.pos_collateral += funding_pnl

        # 4. Check liquidation before action
        liquidated = False
        if self.in_position:
            mm_threshold = self.pos_size * MAINTENANCE_MARGIN_RATE
            if self.pos_collateral < mm_threshold:
                # Liquidated — lose remaining collateral + penalty
                penalty = self.pos_size * LIQUIDATION_PENALTY
                pnl     = self.pos_collateral - penalty
                self.total_pnl   += pnl
                self.free_collateral = max(0, self.free_collateral + pnl)
                self.in_position  = False
                self.pos_size     = 0.0
                self.pos_collateral = 0.0
                liquidated        = True

        # 5. Apply action
        reward = funding_pnl  # shaped reward for surviving funding

        if not liquidated:
            if action == 0:  # Hold
                pass
            elif 1 <= action <= 5:  # Open long
                leverage = action
                reward += self._open_position(True, leverage)
            elif 6 <= action <= 10:  # Open short
                leverage = action - 5
                reward += self._open_position(False, leverage)
            elif action == 11:  # Close
                reward += self._close_position()

        if liquidated:
            reward -= self.pos_size * LIQUIDATION_PENALTY  # extra liquidation penalty

        self.episode_reward += reward

        done      = (self.step_count >= self.n_steps) or (self.free_collateral <= 0)
        truncated = False
        info      = {
            "total_pnl":     self.total_pnl,
            "free_collateral": self.free_collateral,
            "liquidated":    liquidated,
        }
        return self._obs(), float(reward), done, truncated, info

    # ── Helpers ───────────────────────────────────────────────────────────────

    def _open_position(self, is_long: bool, leverage: int) -> float:
        if self.in_position or self.free_collateral < 100:
            return -1.0  # small penalty for invalid action

        collateral  = self.free_collateral * 0.1        # risk 10% of wallet
        collateral  = max(100.0, min(collateral, 10_000.0))
        size        = collateral * leverage

        self.in_position       = True
        self.pos_size          = size
        self.pos_collateral    = collateral
        self.pos_is_long       = is_long
        self.pos_entry_price   = self.mark_price
        self.pos_cum_at_entry  = self.cum_funding
        self.free_collateral  -= collateral
        return 0.0

    def _close_position(self) -> float:
        if not self.in_position:
            return -1.0  # penalty for trying to close when flat

        # Realised PnL from price movement
        if self.pos_is_long:
            price_pnl = self.pos_size * (self.mark_price - self.pos_entry_price) / self.pos_entry_price
        else:
            price_pnl = self.pos_size * (self.pos_entry_price - self.mark_price) / self.pos_entry_price

        total_pnl = price_pnl + (self.pos_collateral - self.pos_size / (self.pos_size / self.pos_collateral))
        # Return collateral + PnL
        returned  = self.pos_collateral + price_pnl
        self.free_collateral += max(0, returned)
        self.total_pnl       += price_pnl
        self.in_position      = False
        self.pos_size         = 0.0
        self.pos_collateral   = 0.0
        return price_pnl

    def _obs(self) -> np.ndarray:
        p0 = INITIAL_BTC_PRICE
        return np.array([
            self.mark_price  / p0,
            self.index_price / p0,
            self.funding_rate,
            self.cum_funding,
            self.pos_size       / p0,
            self.pos_collateral / p0,
            float(self.pos_is_long),
            self.free_collateral / 100_000.0,
        ], dtype=np.float32)


# ─── Training ─────────────────────────────────────────────────────────────────

def train(total_timesteps: int = 200_000, save_path: str = "results/rl_trader"):
    try:
        from stable_baselines3 import PPO
        from stable_baselines3.common.vec_env import DummyVecEnv, VecNormalize
        from stable_baselines3.common.callbacks import EvalCallback
    except ImportError:
        print("[RL] stable-baselines3 not installed. Run: pip install stable-baselines3")
        return None

    os.makedirs(os.path.dirname(save_path) if os.path.dirname(save_path) else ".", exist_ok=True)

    env      = DummyVecEnv([lambda: BarakaTraderEnv(n_steps=720)])
    env_norm = VecNormalize(env, norm_obs=True, norm_reward=True)

    eval_env  = DummyVecEnv([lambda: BarakaTraderEnv(n_steps=720, seed=99)])
    eval_cb   = EvalCallback(eval_env, best_model_save_path=save_path,
                             log_path="results/", eval_freq=10_000,
                             deterministic=True, render=False)

    model = PPO(
        "MlpPolicy", env_norm,
        learning_rate   = 3e-4,
        n_steps         = 2048,
        batch_size      = 64,
        n_epochs        = 10,
        gamma           = 0.99,
        clip_range      = 0.2,
        verbose         = 1,
    )

    print(f"[RL] Training PPO for {total_timesteps:,} timesteps...")
    model.learn(total_timesteps=total_timesteps, callback=eval_cb)
    model.save(save_path)
    env_norm.save(save_path + "_vecnorm.pkl")
    print(f"[RL] Model saved → {save_path}.zip")
    return model


# ─── Evaluation ───────────────────────────────────────────────────────────────

def evaluate(model_path: str, n_episodes: int = 20):
    try:
        from stable_baselines3 import PPO
    except ImportError:
        print("[RL] stable-baselines3 not installed.")
        return

    model    = PPO.load(model_path)
    rewards  = []
    pnls     = []

    for ep in range(n_episodes):
        env   = BarakaTraderEnv(n_steps=720, seed=ep * 7)
        obs, _  = env.reset()
        done  = False
        total_r = 0.0
        while not done:
            action, _ = model.predict(obs, deterministic=True)
            obs, r, done, _, info = env.step(int(action))
            total_r += r
        rewards.append(total_r)
        pnls.append(info["total_pnl"])

    print(f"\n[RL] Evaluation over {n_episodes} episodes:")
    print(f"  Mean episode reward : {np.mean(rewards):.2f} ± {np.std(rewards):.2f}")
    print(f"  Mean total PnL      : ${np.mean(pnls):,.2f} ± ${np.std(pnls):,.2f}")
    print(f"  Profitable episodes : {sum(p > 0 for p in pnls)}/{n_episodes}")

    # Plot reward distribution
    plt.figure(figsize=(8, 4))
    plt.hist(pnls, bins=20, edgecolor="black", color="steelblue")
    plt.axvline(0, color="red", linestyle="--", label="Break-even")
    plt.title("RL Trader — PnL Distribution (Baraka Protocol)")
    plt.xlabel("Total PnL ($)")
    plt.ylabel("Episodes")
    plt.legend()
    os.makedirs("results", exist_ok=True)
    plt.savefig("results/rl_pnl_distribution.png", dpi=150)
    plt.close()
    print("[RL] PnL plot saved → results/rl_pnl_distribution.png")


# ─── CLI ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--train", action="store_true")
    parser.add_argument("--eval",  action="store_true")
    parser.add_argument("--model", default="results/rl_trader")
    parser.add_argument("--timesteps", type=int, default=200_000)
    args = parser.parse_args()

    if args.train:
        train(total_timesteps=args.timesteps, save_path=args.model)
    elif args.eval:
        evaluate(model_path=args.model)
    else:
        # Quick sanity check — run 3 random episodes
        print("[RL] Running 3 random-action episodes for sanity check...")
        for ep in range(3):
            env  = BarakaTraderEnv(seed=ep)
            obs, _ = env.reset()
            done = False
            steps = 0
            while not done:
                action = env.action_space.sample()
                obs, r, done, _, info = env.step(action)
                steps += 1
            print(f"  Episode {ep+1}: {steps} steps, PnL=${info['total_pnl']:,.2f}, "
                  f"final_collateral=${info['free_collateral']:,.2f}")
