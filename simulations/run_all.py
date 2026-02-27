"""
Baraka Protocol — Run All Simulations

Convenience script that runs every simulation module in sequence
and prints a final pass/fail summary.

Modules
-------
  1. cadCAD Monte Carlo
  2. Game Theory
  3. Mechanism Design
  4. Stress Scenarios
  5. Integrated Economic System (cadCAD + RL + Game Theory + Mechanism Design)

Usage:
    cd simulations
    python run_all.py
    python run_all.py --quick   # reduced steps/runs for fast validation
    python run_all.py --skip-integrated  # skip the longer integrated run
"""

import sys, os
sys.path.insert(0, os.path.dirname(__file__))

import argparse
import numpy as np
import pandas as pd

PASS  = "✓ PASS"
FAIL  = "✗ FAIL"
SKIP  = "⚠ SKIP"

results = {}

def check(name: str, passed: bool, detail: str = ""):
    icon  = PASS if passed else FAIL
    results[name] = passed
    print(f"  {icon}  {name:45s} {detail}")


def run_cadcad(steps: int, runs: int):
    print("\n[1/4] cadCAD Monte Carlo Simulation")
    print("-" * 50)
    try:
        from cadcad.run import run_simulation
        df = run_simulation(steps=steps, n_runs=runs)
        last = df[df["step"] == df["step"].max()]

        insolvency_rate = last["protocol_insolvent"].mean()
        fr_max = df["funding_rate"].max()
        fr_min = df["funding_rate"].min()
        in_bounds = (fr_max <= 0.0076) and (fr_min >= -0.0076)

        check("cadCAD: insolvency_rate < 5%",
              insolvency_rate < 0.05,
              f"({insolvency_rate*100:.1f}%)")
        check("cadCAD: funding rate within ±75bps",
              in_bounds,
              f"(range: [{fr_min*10000:.1f}, {fr_max*10000:.1f}] bps)")

        os.makedirs("results", exist_ok=True)
        df.to_csv("results/cadcad_results.csv", index=False)
        print(f"  → Results saved: results/cadcad_results.csv")

    except Exception as e:
        check("cadCAD: simulation",    False, f"ERROR: {e}")
        check("cadCAD: funding rate",  False, "skipped")


def run_game_theory(n_sims: int):
    print("\n[2/4] Game Theory Analysis")
    print("-" * 50)
    try:
        from game_theory.funding_game import compare_iota_regimes, plot_iota_comparison

        results_gt = compare_iota_regimes(n_simulations=n_sims, steps=150,
                                          iota_values=[0.0, 0.001, 0.005])

        iota0 = results_gt[0.0]
        net_transfer_zero = abs(iota0["net_transfer"])
        total_paid_zero   = iota0["mean_paid_longs"] + iota0["mean_paid_shorts"] + 1e-9
        # Relative imbalance < 30% (due to MC variance in quick mode; approaches 0 with more sims)
        relative_imbalance = net_transfer_zero / total_paid_zero

        check("Game theory: ι=0 net_transfer < 30% of total",
              relative_imbalance < 0.30,
              f"({relative_imbalance*100:.1f}% of total paid)")
        check("Game theory: ι=0 is_riba = False",
              not iota0["is_riba"],
              f"(riba={iota0['is_riba']})")
        check("Game theory: ι>0 is_riba = True",
              results_gt[0.005]["is_riba"],
              f"(ι=0.005 riba={results_gt[0.005]['is_riba']})")

        os.makedirs("results", exist_ok=True)
        plot_iota_comparison(results_gt, "results/game_theory_iota.png")

    except Exception as e:
        for label in ["Game theory: ι=0 net_transfer", "Game theory: is_riba checks"]:
            check(label, False, f"ERROR: {e}")


def run_mechanism_design(quick: bool):
    print("\n[3/4] Mechanism Design")
    print("-" * 50)
    try:
        from mechanism_design.parameter_optimizer import fast_simulate

        # Evaluate current Baraka params
        current = fast_simulate({
            "max_funding_rate":    0.0075,
            "maintenance_margin":  0.02,
            "liquidation_penalty": 0.01,
            "insurance_split":     0.50,
        }, steps=50, n_runs=5, seed=42)

        check("Mechanism: current params insolvency_rate < 10%",
              current["insolvency_rate"] < 0.10,
              f"({current['insolvency_rate']*100:.1f}%)")
        check("Mechanism: mean_insurance_end > $0",
              current["mean_insurance_end"] > 0,
              f"(${current['mean_insurance_end']:,.0f})")

    except Exception as e:
        for label in ["Mechanism: insolvency", "Mechanism: insurance"]:
            check(label, False, f"ERROR: {e}")


def run_scenarios():
    print("\n[4/4] Stress Test Scenarios")
    print("-" * 50)
    try:
        from scenarios.flash_crash import run_scenario, SCENARIOS

        for name in SCENARIOS.keys():
            try:
                df = run_scenario(name, n_positions=40)
                survived = not df["insolvent"].any()
                iota_ok  = not df["iota_violated"].any()
                lev_ok   = not df["leverage_violated"].any()
                check(f"Scenario [{name}]: protocol solvent",    survived)
                check(f"Scenario [{name}]: ι=0 maintained",     iota_ok)
                check(f"Scenario [{name}]: max leverage ok",     lev_ok)

                os.makedirs("results", exist_ok=True)
                df.to_csv(f"results/scenario_{name}.csv", index=False)
            except Exception as e:
                check(f"Scenario [{name}]", False, f"ERROR: {e}")

    except Exception as e:
        check("Scenarios: import", False, f"ERROR: {e}")


def run_integrated(steps: int, n_episodes: int, quick: bool):
    print(f"\n[5/5] Integrated Economic System (cadCAD + RL + Game Theory + Mechanism Design)")
    print("-" * 50)
    try:
        from integrated.economic_system import run_integrated_simulation

        res = run_integrated_simulation(
            n_episodes        = n_episodes,
            steps_per_episode = steps,
            quick             = quick,
            seed              = 42,
        )

        eps = res["episodes"]
        gt  = res["gt_analysis"]

        insolv_any  = bool(eps["protocol_insolvent"].any())
        mean_fr     = eps["mean_abs_funding"].mean() * 10_000   # bps
        rl_survived = bool((eps["rl_final_capital"] > 0).all())

        check("Integrated: no insolvent episodes",
              not insolv_any,
              f"({'ALL SOLVENT' if not insolv_any else 'INSOLVENCY DETECTED'})")
        check("Integrated: mean |funding| < circuit breaker",
              mean_fr < 75.0,
              f"({mean_fr:.1f} bps/interval, ι=0 symmetric)")
        check("Integrated: RL agent capital > 0 all episodes",
              rl_survived,
              f"({'yes' if rl_survived else 'agent bankrupted'})")

        if not gt.empty:
            net_tr = abs(gt["net_transfer"].mean())
            check("Integrated: GT net_transfer ≈ $0 (ι=0 riba-free)",
                  net_tr < 1000,
                  f"(${net_tr:,.0f})")

        os.makedirs("results/integrated", exist_ok=True)
        res["timeseries"].to_csv("results/integrated/integrated_timeseries.csv", index=False)
        res["episodes"].to_csv("results/integrated/integrated_episodes.csv", index=False)
        print(f"  → Results saved: results/integrated/")

    except Exception as e:
        import traceback
        check("Integrated: simulation", False, f"ERROR: {e}")
        traceback.print_exc()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--quick", action="store_true",
                        help="Reduced steps/runs for fast validation")
    parser.add_argument("--skip-integrated", action="store_true",
                        help="Skip integrated simulation (faster CI)")
    args = parser.parse_args()

    steps    = 200 if args.quick else 720
    runs     = 5   if args.quick else 20
    sims     = 30  if args.quick else 100
    episodes = 2   if args.quick else 3

    print("=" * 60)
    print("BARAKA PROTOCOL — FULL SIMULATION SUITE")
    print(f"  Mode: {'QUICK' if args.quick else 'FULL'} "
          f"({steps} steps, {runs} MC runs, {sims} GT sims)")
    print("=" * 60)

    run_cadcad(steps, runs)
    run_game_theory(sims)
    run_mechanism_design(args.quick)
    run_scenarios()
    if not args.skip_integrated:
        run_integrated(steps, episodes, args.quick)

    # Final summary
    passed = sum(1 for v in results.values() if v)
    total  = len(results)
    all_passed = (passed == total)

    print("\n" + "=" * 60)
    print(f"SIMULATION SUITE: {passed}/{total} checks passed")
    if all_passed:
        print("  ✓ ALL CHECKS PASSED — Protocol ready for testnet deployment")
    else:
        failed = [k for k, v in results.items() if not v]
        print(f"  ✗ {len(failed)} CHECKS FAILED:")
        for f in failed:
            print(f"    - {f}")
        print("  Review failed checks before deploying to testnet.")
    print("=" * 60)

    sys.exit(0 if all_passed else 1)
