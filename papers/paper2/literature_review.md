# Literature Review — Paper 2
## "From Perpetual Contracts to Islamic Credit: The Random Stopping Time Equivalence"
### Master Reference File — March 2026

---

## How to Read This File

Each entry has four fields:
- **What it is** — the paper/book in one sentence
- **Core finding** — the key result or argument
- **How it relates to us** — what we directly build on or cite it for
- **What it missed** — the gap our paper fills relative to this work

References are grouped by intellectual strand.

---

## STRAND 1: Perpetual Contract Theory

---

### Ackerer, D., Hugonnier, J., & Jermann, U.J. (2024)
**"Perpetual futures pricing"**
*Mathematical Finance*, 34(4), 1277–1308.

**What it is:** The foundational paper proving that perpetual futures contracts have a unique, arbitrage-free price. Introduces the convergence intensity κ, the interest parameter ι, and the random time representation.

**Core finding:** Theorem 3 proves ι=0 satisfies all no-arbitrage conditions. Theorem 6 establishes the random time representation: f_t = E[e^{-∫ι dt} · X_{θ}], where θ ~ Exp(κ−ι). Proposition 6 gives closed-form everlasting option prices as power solutions to a PDE.

**How it relates to us:** This is our primary mathematical foundation. Without Ackerer et al., the equivalence we establish cannot be stated. Every theorem in our paper either cites or directly applies their results. The ι=0 proof is the hinge of our entire argument: because ι=0 is no-arbitrage in their framework, r=0 is no-arbitrage in ours (by the isomorphism we prove).

**What it missed:** The paper is entirely about derivatives pricing for crypto/equity perpetual futures. It makes no connection to: (1) the Islamic finance literature, (2) the reduced-form credit risk literature (Duffie-Singleton), (3) the possibility that κ could replace the risk-free rate r in a complete credit pricing system. The random time representation is presented as a mathematical convenience, not as a structural theorem about the separability of interest from credit risk. That observation — and all its Islamic finance implications — is ours.

---

### Shiller, R.J. (1993)
**"Macro Markets: Creating Institutions for Managing Society's Largest Economic Risks"**
*Oxford University Press*

**What it is:** A visionary book proposing perpetual financial contracts on macroeconomic aggregates (GDP, housing indices, labor income) as a tool for risk sharing at societal scale.

**Core finding:** Argues that missing markets for long-run macroeconomic risks cause persistent welfare losses, and that perpetual contracts (with no fixed expiry) are the natural instrument to complete these markets.

**How it relates to us:** Establishes the intellectual lineage of perpetual contracts as genuine economic instruments for risk transfer, not just derivatives curiosities. Cited in our related literature to show that perpetuals have been proposed as risk-sharing tools — which is precisely their Islamic finance application.

**What it missed:** Shiller's perpetuals are conceptual and institutional, not mathematically priced. He does not develop a no-arbitrage pricing formula. He makes no connection to Islamic finance, credit risk, or the interest-free pricing problem. The mathematical machinery needed to actually implement his vision at ι=0 is provided by Ackerer et al. (2024) and applied in our paper.

---

## STRAND 2: Reduced-Form Credit Risk Models

---

### Jarrow, R.A., & Turnbull, S.M. (1995)
**"Pricing derivatives on financial securities subject to credit risk"**
*Journal of Finance*, 50(1), 53–85.

**What it is:** The paper that launched intensity-based (reduced-form) credit risk modeling. Models default as the first event of a Poisson process with a deterministic hazard rate.

**Core finding:** Default arrival can be modeled as an exogenous random event rather than derived from firm value dynamics (structural approach). The price of a credit-risky instrument is the expected discounted payoff under a risk-neutral measure that adjusts for the default probability. Requires r > 0.

**How it relates to us:** This is the origin paper of the mathematical framework we show is isomorphic to Ackerer et al. The Poisson default process they introduce is structurally identical to the Cox stopping time in the perpetual futures framework. We cite it as the starting point of the literature we are connecting to Islamic finance.

**What it missed:** The hazard rate λ is treated as a separate object from the risk-free rate r — but the two are bundled in the discount factor e^{-(r+λ)t}. Jarrow-Turnbull do not ask whether r could be zero and pricing still work. They assume r > 0 throughout. The possibility of separating r from λ — which our paper formalizes — is not considered.

---

### Duffie, D., & Singleton, K.J. (1999)
**"Modeling term structures of defaultable bonds"**
*Review of Financial Studies*, 12(4), 687–720.

**What it is:** The defining paper of reduced-form credit risk. Extends Jarrow-Turnbull to affine stochastic hazard rates, establishes the risk-adjusted short-rate representation, and derives the key pricing formula P_t = E[e^{-∫r dt} · φ(X_τ)].

**Core finding:** Under the "recovery of market value" assumption, defaultable bond pricing reduces to risk-free bond pricing with an adjusted short rate r + λ(1−δ), where λ is the hazard rate and δ the recovery fraction. This is the standard practitioner formula for CDS spreads and bond pricing.

**How it relates to us:** This is the other side of our isomorphism. The Duffie-Singleton formula P_t = E[e^{-∫r dt} · φ(X_τ)] is structurally identical to the Ackerer formula f_t = E[e^{-∫ι dt} · X_θ] under τ↔θ, λ↔κ, r↔ι. We cite the 1999 paper as the source of the formula we show is isomorphic to Ackerer et al.

**What it missed:** Duffie and Singleton never consider r=0 as a viable pricing regime. The entire framework assumes r > 0 as a prerequisite for meaningful discounting. They do not ask what happens mathematically if ι (the interest parameter in the perpetual framework they had not seen, published 25 years later) were zero. The Islamic finance context — and the possibility that their framework implies a complete riba-free pricing system — is entirely absent.

---

### Duffie, D., & Singleton, K.J. (2003)
**"Credit Risk: Pricing, Measurement, and Management"**
*Princeton University Press*

**What it is:** The book-length treatment of reduced-form credit risk, synthesizing the 1999 paper and subsequent work into a comprehensive framework covering CDS pricing, CDO valuation, portfolio credit risk, and risk management.

**Core finding:** Provides the complete mathematical and practical apparatus for credit risk pricing, with r embedded as a fundamental input throughout. The "adjusted short rate" r + λ(1−δ) is the book's central organizing formula.

**How it relates to us:** We cite it as the authoritative reference for the full credit risk machinery that our κ-rate framework inherits. When we claim the "entire reduced-form machinery transfers to Islamic finance under ι=r=0," the machinery we refer to is documented in this book.

**What it missed:** As with the 1999 paper, r > 0 is never questioned. The book does not consider negative-rate environments (written before the ECB NIRP experiment). Islamic finance is not mentioned. The possibility of replacing r with an endogenous intensity parameter κ is not explored.

---

### Lando, D. (1998)
**"On Cox processes and credit risky securities"**
*Review of Derivatives Research*, 2(2–3), 99–120.

**What it is:** Establishes the rigorous Cox process (doubly stochastic Poisson process) treatment of credit risk, showing that stochastic hazard rates generate survival probabilities via the Laplace transform of the integrated intensity.

**Core finding:** The default time τ conditional on the filtration generated by the background process is an exponentially distributed stopping time with random rate λ_t. The survival probability Q(τ > t) = E[e^{-∫λ dt}] mirrors standard interest rate discounting.

**How it relates to us:** The Cox process is exactly what generates our stopping time θ in the Ackerer framework. Lando's result justifies using the same filtration enlargement techniques for the κ-parameterized stopping time that he uses for the hazard rate λ. We cite him as establishing the mathematical foundations of intensity-based default modeling.

**What it missed:** Lando does not connect the Cox process intensity to perpetual contract pricing. He does not consider ι=0 or λ=0 as a viable regime. Islamic finance is absent.

---

### Bielecki, T.R., & Rutkowski, M. (2002)
**"Credit Risk: Modeling, Valuation and Hedging"**
*Springer-Verlag, Berlin*

**What it is:** The definitive mathematical textbook of credit risk, covering structural and reduced-form models, filtration enlargement, copula models for portfolio credit, and hedging strategies.

**Core finding:** Provides the complete mathematical apparatus: filtration enlargement theorems (how to compute E[·|F_t] when τ is not adapted to the background filtration), survival probabilities under stochastic intensities, and the connection between default intensity and martingale theory.

**How it relates to us:** The filtration enlargement results (Chapters 6–7) are directly used in our stochastic-κ extension (Section 7.3). When we state that the stopping time density is well-defined under stochastic κ following a CIR process, the mathematical justification is in Bielecki-Rutkowski. We cite it as the comprehensive reference for the technical machinery underlying our framework.

**What it missed:** Like all credit risk texts, r > 0 is assumed throughout. The book surveys all major credit risk models but does not connect any of them to the Ackerer perpetual contract framework (published 22 years later) or to Islamic finance. The Separation Theorem — that r is a separable, eliminable component — is not articulated.

---

### Elliott, R.J., Jeanblanc, M., & Yor, M. (2000)
**"On models of default risk"**
*Mathematical Finance*, 10(2), 179–195.

**What it is:** Resolves the filtration enlargement problem in credit risk: how to compute conditional expectations when the default time τ is not measurable with respect to the background (market) filtration F_t.

**Core finding:** Under a technical "H-hypothesis" (conditional independence between the market filtration and the default filtration), the survival probability decomposes cleanly and pricing formulas remain tractable.

**How it relates to us:** The H-hypothesis ensures that our stopping time θ (the κ-parameterized perpetual stopping time) can be handled consistently within the credit risk framework. When we map θ ↔ τ, the filtration structure must be compatible — Elliott-Jeanblanc-Yor guarantees this.

**What it missed:** Technical mathematical paper with no Islamic finance content. Does not connect to perpetual contracts or consider r=0.

---

### Jeanblanc, M., Yor, M., & Chesney, M. (2009)
**"Mathematical Methods for Financial Markets"**
*Springer-Verlag, London*

**What it is:** The definitive 758-page mathematical synthesis of stochastic calculus for finance, with comprehensive treatment of credit risk, stopping times, filtration enlargement, and Laplace transforms.

**Core finding:** Provides Proposition 6.3.4 giving the Laplace transform of ∫κ_t dt under the CIR specification — directly needed for our stochastic-κ extension. Also provides the most complete treatment of the filtration enlargement problem and Cox process intensity theory.

**How it relates to us:** We use it in Section 7.3 for the stochastic-κ CIR extension. The closed-form bond price functions A(·) and B(·) in our equation (CIR Laplace transform) come from this book. It is our primary reference for the mathematical foundations underlying stochastic intensity models.

**What it missed:** Encyclopedic mathematical reference with no Islamic finance content. Does not connect the stopping time framework to ι=0 pricing or the Ackerer equivalence.

---

### Jeanblanc, M., & Rutkowski, M. (2000)
**"Modelling of default risk: An overview"**
*In: Mathematical Finance: Theory and Practice, Higher Education Press, Beijing*

**What it is:** A survey paper documenting the state of default risk modeling at the turn of the millennium, covering both structural and reduced-form approaches.

**Core finding:** Provides a unified overview showing both modeling traditions share the common structure of a random stopping time for the default event. This survey planted the seed for later synthesis work.

**How it relates to us:** Cited for the overview of the default time modeling framework and the filtration enlargement setup that underlies our equivalence proof.

**What it missed:** Survey paper — does not develop new results. No Islamic finance content. Written before Ackerer et al. (2024).

---

### Duffie, D., & Lando, D. (2001)
**"Term structures of credit spreads with incomplete accounting information"**
*Econometrica*, 69(3), 633–664.

**What it is:** Extends the Duffie-Singleton framework to the case where the firm's asset value is not perfectly observable (incomplete information), showing that incomplete accounting information generates realistic credit spread term structures.

**Core finding:** Even firms with low default risk can show positive short-term credit spreads if accounting information is noisy — resolving the "credit spread puzzle" in structural models.

**How it relates to us:** Shows that intensity-based credit modeling is robust to information asymmetry — a property the κ-rate framework inherits. In our sukuk application, the κ parameter calibrated from observable market prices already incorporates information asymmetry implicitly.

**What it missed:** Incomplete information analysis within a conventional r > 0 framework. No Islamic finance content. The κ-based analog (how information asymmetry affects κ calibration) is an open research question noted in our Limitations section.

---

### Schönbucher, P.J. (2003)
**"Credit Derivatives Pricing Models: Models, Pricing and Implementation"**
*John Wiley & Sons, Chichester*

**What it is:** The standard practitioner reference for credit derivatives pricing, covering CDS, CDOs, basket products, and copula models, with implementation guidance.

**Core finding:** Synthesizes the Duffie-Singleton reduced-form framework into a complete toolkit for valuing the $10T credit derivatives market. The CDS spread formula s = λ(1−δ) (approximately) is the book's central pricing result.

**How it relates to us:** Our iCDS pricing formula s* = κ(1−δ) is structurally identical to Schönbucher's CDS formula s = λ(1−δ), with κ replacing λ and r=0 instead of r>0. We cite him to show that the practitioner credit market formula has an exact Islamic analog.

**What it missed:** Entirely r>0 framework. No consideration of r=0 pricing. Islamic finance absent. The possibility that λ could be identified with κ from a perpetual contract framework is not considered.

---

## STRAND 3: Mathematical Finance Foundations

---

### Harrison, J.M., & Kreps, D.M. (1979)
**"Martingales and arbitrage in multiperiod securities markets"**
*Journal of Economic Theory*, 20(3), 381–408.

**What it is:** The foundational paper establishing the equivalence between no-arbitrage and the existence of a risk-neutral (equivalent martingale) measure.

**Core finding:** A price process admits no arbitrage if and only if there exists a probability measure Q equivalent to P under which all discounted price processes are martingales. This is the mathematical basis for all modern derivative pricing.

**How it relates to us:** Our Corollary 1 (riba-free credit pricing is no-arbitrage) inherits its validity from the Harrison-Kreps theorem via the Ackerer et al. no-arbitrage proof. When we say "no-arbitrage at ι=0 implies no-arbitrage at r=0," the concept of no-arbitrage we invoke is Harrison-Kreps.

**What it missed:** Written 45 years before the Ackerer framework, this foundational paper has no content on perpetual contracts, Islamic finance, or ι=0 pricing. It provides the mathematical language but not the specific application.

---

### Brémaud, P. (1981)
**"Point Processes and Queues: Martingale Dynamics"**
*Springer-Verlag, New York*

**What it is:** The definitive mathematical reference for point processes (random events occurring at random times), martingale theory, and their applications to queuing and stochastic systems.

**Core finding:** Establishes the martingale representation of point processes, the compensator theory (how to remove the predictable drift from a point process to obtain a martingale), and the Doob-Meyer decomposition for jump processes.

**How it relates to us:** The Cox process (doubly stochastic Poisson process) that generates our stopping time θ and the default time τ is a point process in Brémaud's sense. The survival probability formula Q(θ > t) = E[e^{-∫κ dt}] is derived using his compensator theory. We cite him as the mathematical foundation of the stopping time density formula.

**What it missed:** Pure mathematics reference. No connection to Islamic finance, perpetual contracts, or credit derivatives.

---

### Black, F., & Scholes, M. (1973)
**"The pricing of options and corporate liabilities"**
*Journal of Political Economy*, 81(3), 637–654.

**What it is:** The paper that launched modern derivatives pricing — the Black-Scholes option pricing formula.

**Core finding:** Under geometric Brownian motion and continuous hedging, the option price satisfies a PDE whose solution gives the famous formula. Requires the risk-free rate r as a discount factor.

**How it relates to us:** The everlasting option prices in our paper (Section 5) reduce to Black-Scholes-like closed forms — power solutions C·x^β — when ι=0. The characteristic equation β(β−1)σ²/2 = κ is the perpetual analog of the Black-Scholes PDE. We note the structural similarity to contextualize the everlasting option formulas for readers familiar with standard options theory.

**What it missed:** Finite-maturity options only. The r > 0 assumption is structural (needed for the terminal condition at expiry). No perpetual contracts, no Islamic finance, no stopping time representation.

---

### Cox, J.C., Ingersoll, J.E., & Ross, S.A. (1985)
**"A theory of the term structure of interest rates"**
*Econometrica*, 53(2), 385–408.

**What it is:** The CIR model — the most widely used model for interest rate dynamics, featuring mean reversion and non-negative rates.

**Core finding:** Interest rates follow dκ = α(κ̄ − κ)dt + ν√κ dZ. The bond price has a closed-form Laplace transform A(T)e^{−B(T)κ}. The square-root diffusion ensures rates remain positive.

**How it relates to us:** In Section 7.3 (Stochastic κ), we use the CIR specification for time-varying κ. The Laplace transform of ∫κ_t dt under CIR gives the closed-form generalization of our stopping time distribution. The CIR functions A(·) and B(·) appear directly in our stochastic-κ pricing formula. We are repurposing a model developed for interest rates to instead parameterize a riba-free event intensity.

**What it missed:** CIR is an interest rate model — κ in our framework replaces r, not ι. The conceptual reuse (applying CIR to an intensity that has no interest content) is our contribution, not theirs.

---

### Protter, P.E. (2005)
**"Stochastic Integration and Differential Equations"** (2nd ed.)
*Springer-Verlag, Berlin*

**What it is:** The standard graduate textbook for stochastic calculus, covering Itô integrals, semimartingales, SDEs, and their applications to mathematical finance.

**Core finding:** Establishes the theoretical foundations of stochastic integration that underlie all continuous-time finance models, including the filtration conditions ("usual conditions") that ensure well-posedness of conditional expectations.

**How it relates to us:** Cited as the reference for the probability space and filtration setup in our market setup (Section 2.1). The "usual conditions" assumption on (Ω, F, P) is the standard Protter setup.

**What it missed:** Pure mathematics reference. No Islamic finance content.

---

## STRAND 4: Islamic Finance — Jurisprudence and Economics

---

### El-Gamal, M.A. (2006)
**"Islamic Finance: Law, Economics, and Practice"**
*Cambridge University Press*

**What it is:** The most rigorous economic analysis of Islamic finance — its theory, practice, and shortcomings. Written by an Islamic economist who is also a trained mathematician.

**Core finding:** Most Islamic finance products are "form over substance" — they replicate conventional interest-bearing instruments through legal rearrangement without genuine economic difference. The riba prohibition is economically significant but Islamic finance has largely failed to implement genuine alternatives.

**How it relates to us:** El-Gamal's critique is the negative motivation for our paper. He documents exactly the gap we claim to fill: the absence of a genuine mathematical alternative to riba-based credit pricing. We cite him extensively to establish the problem statement. His definition of riba (predetermined excess) is what we show the κ-rate framework avoids.

**What it missed:** El-Gamal is an institutional and legal economist, not a mathematical finance theorist. He correctly identifies the problem but does not propose (or believe possible) a mathematically rigorous alternative pricing system. He does not engage with the stopping time / perpetual contract literature. Our paper provides the mathematical solution to the problem he identified.

---

### Usmani, M.T. (2002)
**"An Introduction to Islamic Finance"**
*Kluwer Law International, The Hague*

**What it is:** The authoritative jurisprudential text on Islamic finance from the most prominent Shariah scholar in the field. Justice Usmani has sat on AAOIFI Shariah boards and shaped global sukuk standards.

**Core finding:** Comprehensive jurisprudential analysis of riba, its two forms (al-fadl and al-nasi'ah), and its application to modern financial instruments. Establishes that predetermined returns on capital are prohibited under all schools.

**How it relates to us:** We use Usmani as the primary jurisprudential authority for defining riba in Section 8.1. The two-form typology (riba al-fadl / riba al-nasi'ah) frames our argument about why ι=0 and r=0 satisfy Shariah requirements. His analysis of what constitutes riba is the standard we show the κ-rate framework meets.

**What it missed:** Jurisprudential scholar, not a mathematician. Usmani understands the legal prohibition but cannot provide the mathematical proof that a riba-free credit pricing system exists. That is our contribution.

---

### Chapra, M.U. (1985)
**"Towards a Just Monetary System"**
*The Islamic Foundation, Leicester*

**What it is:** A landmark book in Islamic economics arguing for a complete reconstruction of the monetary system on Islamic principles — abolishing interest, restructuring central banking, and replacing the risk-free rate with profit-sharing mechanisms.

**Core finding:** The interest rate is not just jurisprudentially prohibited but also economically harmful — it distorts resource allocation, promotes debt over equity, and concentrates wealth. An Islamic monetary system based on profit-and-loss sharing would be more just and more stable.

**How it relates to us:** Chapra's normative vision — a monetary system without the risk-free rate r — is exactly what our κ-rate framework mathematically enables. The κ-yield curve (Section 7.4) is a concrete implementation of Chapra's "Islamic term structure." We cite him to show the κ-rate framework has deep intellectual roots in Islamic monetary economics, not just in our technical innovation.

**What it missed:** Chapra is an economist and ethicist, not a mathematician. He does not provide the mathematical proof that his vision is consistent with no-arbitrage pricing. His proposed profit-sharing mechanisms lack the closed-form pricing formulas that financial markets require for implementation. Our paper provides the missing mathematics.

---

### Iqbal, Z., & Mirakhor, A. (2011)
**"An Introduction to Islamic Finance: Theory and Practice"** (2nd ed.)
*John Wiley & Sons, Singapore*

**What it is:** A comprehensive textbook on Islamic finance covering instruments, institutions, risk management, and the theoretical framework from a normative Islamic economics perspective.

**Core finding:** Islamic finance should be based on genuine risk-sharing (mudarabah, musharakah) rather than debt-like instruments. The industry has deviated from this ideal; genuine risk-sharing requires new financial instruments and pricing methodologies.

**How it relates to us:** Cited for the normative framework motivating our work. The "genuine risk-sharing" requirement maps directly to our framework: the κ-rate perpetual sukuk structure is risk-sharing (both parties bear the uncertainty of τ), not a guaranteed return on capital.

**What it missed:** Like Chapra, Iqbal-Mirakhor identify the goal but not the mathematical path. The pricing formulas required to implement genuine risk-sharing instruments do not appear.

---

### Kamali, M.H. (2007)
**"Islamic Commercial Law: An Analysis of Futures and Options"**
*The Islamic Texts Society, Cambridge*

**What it is:** The definitive jurisprudential analysis of futures and options contracts from an Islamic perspective — examining whether and under what conditions derivatives are permissible.

**Core finding:** Traditional scholars prohibited futures as gambling (maysir) and options as speculative. Kamali argues for conditional permissibility when: the underlying is real, the contract serves economic risk management, and excessive uncertainty (gharar) is absent. Distinguishes permissible hedging from prohibited gambling.

**How it relates to us:** Our Section 8.2 (Gharar analysis) and 8.3 (Maysir analysis) draw on Kamali's framework. The distinction between actuarial uncertainty (priced by κ) and contractual ambiguity (gharar) is Kamali's. His conditional permissibility criteria are exactly what the κ-rate framework satisfies by construction.

**What it missed:** Kamali is a Shariah scholar, not a derivatives mathematician. He establishes the jurisprudential conditions for permissibility but cannot verify whether any specific pricing formula meets those conditions. Our paper provides that verification.

---

### Kahf, M. (1994)
**"Time value of money and discounting in Islamic perspective: Re-visited"**
*Review of Islamic Economics*, 3(2), 31–38.

**What it is:** An Islamic economics paper arguing that time value of money — in the sense of opportunity cost — can be Islamically justified, even though interest per se is prohibited.

**Core finding:** The return on productive capital is not riba. If capital deployed today generates real output, a premium for early deployment is economically grounded in productivity, not predetermined excess. This creates a conceptual space for some form of time preference in Islamic finance.

**How it relates to us:** We cite Kahf as Counterargument 1 in Section 8.3. His argument — that opportunity cost justifies time preference — is the strongest challenge to our framework. We respond: κ already captures opportunity cost (faster convergence = sooner payoff = less opportunity cost lost), so the Separation Theorem does not deny Kahf's economics, it shows his argument does not require r > 0.

**What it missed:** Kahf does not provide a pricing formula. He opens a conceptual door but does not walk through it. Our κ-rate framework is precisely the implementation of his intuition — opportunity cost captured by κ without interest.

---

### Siddiqi, M.N. (2004)
**"Riba, Bank Interest and the Rationale of Its Prohibition"**
*Islamic Research and Training Institute, Jeddah*

**What it is:** A systematic treatise on the rationale for prohibiting riba — arguing from both theological and economic grounds that interest causes injustice and that Islamic finance must find genuine alternatives.

**Core finding:** Prohibition of interest is absolute in Islamic law. Workarounds that replicate interest economics while avoiding the label are not compliant. Genuine alternatives must be mathematically different, not just nominally so.

**How it relates to us:** Siddiqi establishes the "genuineness" requirement that our paper satisfies. He is cited in Counterargument 1 as the authority demanding that alternatives be mathematical rather than cosmetic — which is precisely the standard we meet (the κ-rate framework is provably different from r, not just relabeled).

**What it missed:** Like other Islamic economists, Siddiqi identifies what is needed but cannot provide the mathematics. The rigorous proof that a genuine alternative exists is our contribution.

---

### SeekersGuidance. (2025)
**"Are crypto perpetual contracts still haram if there's no interest, and the asset price tracks?"**
Answered by Shaykh Muhammad Carr; approved by Shaykh Faraz Rabbani.

**What it is:** A contemporary Shariah ruling (fatwa) on the specific question of whether crypto perpetual futures contracts are permissible if the ι (interest) parameter is set to zero.

**Core finding:** The ruling concedes that "removing the interest component resolves the riba objection." With ι=0, the contract no longer has a predetermined excess, and the remaining concerns (speculation, gharar) become matters of use-case rather than structural prohibition.

**How it relates to us:** This is the most directly relevant Shariah validation of our work. The ruling answers the jurisprudential question about our foundational design choice (ι=0) affirmatively, by one of the most respected contemporary Shariah authorities. We cite it in Section 8.1 as contemporary validation of the ι=0 approach.

**What it missed:** The ruling addresses perpetual futures only, not the credit applications (sukuk, takaful, iCDS). The extension to credit instruments using the κ-rate framework requires the additional mathematical analysis of our paper to be submitted for Shariah review. This is future work.

---

### AAOIFI. (2017)
**"Shariah Standards for Islamic Financial Institutions"**
*Accounting and Auditing Organization for Islamic Financial Institutions, Manama*

**What it is:** The comprehensive Shariah standard-setting document covering all major Islamic finance products. Relevant standards: No. 17 (Investment Sukuk), No. 21 (Financial Paper), No. 26 (Islamic Insurance/Takaful).

**Core finding:** Standard 17 requires sukuk to represent real ownership in assets (not just debt). Standard 26 requires takaful contributions to be actuarially determined. Standard 21 permits wa'd-based credit enhancement under specific conditions.

**How it relates to us:** Our three main applications are mapped directly to these standards in Section 8.4. The Islamic Perpetual Sukuk satisfies Standard 17 (real asset ownership + wa'd redemption mechanism). Everlasting Takaful satisfies Standard 26 (actuarially fair contributions via the κ-rate formula). iCDS satisfies Standard 21 (wa'd-based risk transfer).

**What it missed:** AAOIFI standards are institutional/regulatory documents, not mathematical frameworks. They establish the compliance criteria but do not provide pricing formulas. Our paper provides the pricing formula that satisfies their criteria.

---

## STRAND 5: Sukuk Pricing and Markets

---

### Khan, T., & Abdallah, A. (2017)
**"Rethinking sukuk pricing: The ghost of LIBOR"**
*Int'l Journal of Islamic and Middle Eastern Finance and Management*, 10(4), 492–511.

**What it is:** Documents the specific mechanism by which LIBOR/SOFR is embedded in sukuk pricing at issuance, making the interest rate implicit even in structures that appear Shariah-compliant on the surface.

**Core finding:** The "ghost of LIBOR" — the benchmark interest rate — haunts every sukuk regardless of its structural form, because pricing at issuance uses the yield spread over a risk-free benchmark. This makes most sukuk economically equivalent to interest-bearing bonds.

**How it relates to us:** This paper is the direct motivation for our sukuk application (Section 6.1). Khan-Abdallah name the problem precisely; our κ-rate framework is the solution. The κ-parameterized sukuk pricing formula (Proposition 3) does not reference LIBOR/SOFR at any step.

**What it missed:** Documents the problem but proposes no mathematical solution. The authors recognize the need for a riba-free pricing formula but do not derive one. Our paper provides that formula.

---

### Reboredo, J.C., Ugolini, A., & Al-Yahyaee, K.H. (2021)
**"Yield spread determinants of sukuk and conventional bonds"**
*Economic Modelling*, 105, 105664.

**What it is:** Empirical study comparing yield spread determinants of sukuk versus conventional bonds across multiple Muslim-majority markets (Saudi Arabia, Malaysia, UAE, Indonesia, Turkey), 2008–2019.

**Core finding:** Sukuk spreads are primarily driven by credit-specific factors (credit rating, firm fundamentals, macro conditions) rather than interest rate sensitivity. The spread behavior is similar to conventional bonds — confirming that the credit risk machinery (hazard rates, recovery) drives both, even when the instruments are structured differently.

**How it relates to us:** This paper provides empirical grounding for our key claim: the κ-rate framework preserves the same spread dynamics as conventional credit models (because κ plays the same role as λ), while removing the riba component r. The empirical finding that spreads are credit-driven (not rate-driven) supports our thesis that r is separable from the credit risk component.

**What it missed:** The paper identifies what drives spreads empirically but does not offer a riba-free pricing formula. It confirms the problem (SOFR-embedded spreads) without providing the solution.

---

### Hassan, M.K., Paltrinieri, A., Dreassi, A., & Haddad, A. (2021)
**"Sukuk and bond spreads"**
*Journal of Economics and Finance*, 45(3), 529–543.

**What it is:** Compares risk-return profiles of sukuk and conventional bonds, focusing on spread behavior and co-integration.

**Core finding:** Sukuk spreads are co-integrated with conventional bond spreads in most markets, suggesting they share the same underlying risk dynamics. Sukuk do not offer a distinct credit risk premium separate from their conventional counterparts.

**How it relates to us:** Confirms that the credit risk channel (hazard rate) is the primary driver of both sukuk and bond pricing — supporting our equivalence result that swapping λ for κ (with r=0) preserves the essential pricing dynamics.

**What it missed:** As with Reboredo et al., confirms the empirical pattern but provides no riba-free pricing framework.

---

### Cakir, S., & Raei, F. (2007)
**"Sukuk vs. Eurobonds: Is there a difference in value-at-risk?"**
*IMF Working Paper WP/07/237*

**What it is:** IMF working paper comparing the risk characteristics (VaR, tail risk) of sukuk and Eurobonds from sovereign issuers in Muslim-majority countries.

**Core finding:** Sukuk and Eurobonds from the same issuer have similar risk profiles, confirming that the underlying credit risk dominates any structural differences. Sukuk do not provide diversification benefits relative to conventional bonds from the same issuer.

**How it relates to us:** Early empirical confirmation that the credit risk channel (κ in our framework) is what matters for pricing — not the interest rate channel (r). Supports the Separation Theorem: if sukuk and Eurobonds share the same risk even though their structures differ, it is because credit risk (not interest) is the fundamental pricing driver.

**What it missed:** 2007 paper, before the full development of the SOFR transition or modern perpetual contract theory. No mathematical pricing framework is proposed.

---

### Jobst, A.A. (2007)
**"The economics of Islamic finance and securitization"**
*Journal of Structured Finance*, 13(1), 6–27.

**What it is:** IMF economist's analysis of Islamic securitization (sukuk) from a structured finance perspective — comparing Islamic structures to their conventional equivalents.

**Core finding:** Islamic securitization replicates the economic characteristics of conventional ABS/CDO structures through legal restructuring. The economics are equivalent, but the legal forms differ to satisfy Shariah requirements. This makes Islamic securitization more expensive (due to additional legal steps) without providing genuine economic differentiation.

**How it relates to us:** Cited to establish the context of the sukuk market and the "form over substance" critique that our framework aims to address. The additional cost Jobst documents is partly a consequence of the absence of a mathematical pricing framework that is natively Shariah-compliant — the κ-rate framework eliminates the need for legal restructuring.

**What it missed:** Does not propose a riba-free mathematical pricing framework. Views Islamic finance as institutional and legal rather than mathematically distinctive.

---

### Jobst, A.A., Kunzel, P., Mills, P., & Sy, A. (2008)
**"Islamic bond issuance: What sovereign debt managers need to know"**
*Int'l Journal of Islamic and Middle Eastern Finance*, 1(4), 330–344.

**What it is:** IMF policy paper guiding sovereign debt managers on sukuk issuance — covering structures, legal requirements, investor base, and pricing.

**Core finding:** Sovereign sukuk are priced against the sovereign's conventional bond yield curve (which is riba-based). There is no sovereign-specific Islamic pricing benchmark. Sukuk issuance grows because of investor demand from Islamic institutional investors, not because the pricing is genuinely different.

**How it relates to us:** Documents the specific problem our sovereign sukuk application (Section 6.4) addresses. The κ-yield curve (Section 7.4) is a direct response to the absence of a sovereign Islamic pricing benchmark identified by Jobst et al.

**What it missed:** Policy paper identifying a gap (no Islamic pricing benchmark). Does not provide the mathematical framework to fill it. That is our contribution.

---

### Adam, N.J., & Thomas, A. (2004)
**"Islamic Bonds: Your Guide to Issuing, Structuring and Investing in Sukuk"**
*Euromoney Books, London*

**What it is:** The practitioner's handbook on sukuk structures, covering all major types (ijarah, murabahah, musharakah, mudharabah sukuk) and their legal documentation requirements.

**Core finding:** Comprehensive documentation of how sukuk are structured in practice — the purchase undertaking (wa'd) mechanism, Special Purpose Vehicle (SPV) arrangements, and AAOIFI compliance procedures.

**How it relates to us:** The wa'd (purchase undertaking) mechanism described in Adam-Thomas is the structural analog of our random redemption trigger. When we map our stopping time τ to a "Shariah board-triggered redemption event," the legal mechanism is the wa'd — and Adam-Thomas is the reference for how that mechanism works in practice.

**What it missed:** Practitioner/legal guide with no mathematical pricing theory. Does not provide no-arbitrage pricing formulas.

---

### IIFM. (2023)
**"Sukuk Report: A Comprehensive Study of the Global Sukuk Market"** (13th ed.)
*International Islamic Financial Market, Manama*

**What it is:** The authoritative annual market study of global sukuk issuance, covering volumes, structures, jurisdictions, and pricing trends.

**Core finding:** Global sukuk outstanding exceeds $800B; annual new issuance runs ~$200B. Sovereign sukuk dominate; ijarah structures are most common. All pricing references SOFR/local government benchmarks.

**How it relates to us:** Provides the market size context for our applications. The SOFR-anchoring of all $800B of outstanding sukuk is the scale of the problem our κ-rate framework addresses. Cited to establish the TAM (total addressable market) for a genuine riba-free pricing alternative.

**What it missed:** Market report — does not propose pricing frameworks.

---

### IFSB. (2024)
**"Islamic Financial Services Industry Stability Report 2024"**
*Islamic Financial Services Board, Kuala Lumpur*

**What it is:** The authoritative annual stability assessment of the $3T Islamic finance industry.

**Core finding:** The Islamic finance industry has grown to $3.37T in assets. Key risks include concentration, SOFR transition, and the absence of standardized risk management tools (particularly credit derivatives). The iCDS gap is explicitly noted as a systemic vulnerability.

**How it relates to us:** The IFSB stability report is the authoritative source for our opening claim ($3T industry, no credit derivatives). The "absence of credit derivatives" finding is the direct motivation for our iCDS application (Section 6.3).

**What it missed:** Industry report — identifies vulnerabilities but proposes no mathematical solutions.

---

## STRAND 6: Takaful Pricing

---

### Billah, M.M. (2007)
**"Islamic Insurance (Takaful)"**
*Sweet & Maxwell Asia, Petaling Jaya*

**What it is:** The standard reference text on takaful — covering its jurisprudential foundations, operational structures (wakalah, mudharabah, hybrid models), and comparison with conventional insurance.

**Core finding:** Takaful contributions should be based on risk-sharing principles (participants donate into a mutual pool, tabarru') rather than a predetermined return on investment. The pool invests in Shariah-compliant instruments. The tension between actuarial fairness and riba-free pricing is identified but not resolved.

**How it relates to us:** Billah identifies the core tension that the everlasting takaful formula resolves. His definition of tabarru' (mutual donation/contribution) maps directly to the continuous premium π_t in our takaful definition (Definition 4). The actuarial fairness requirement in his framework is what our Theorem 2 (Actuarially Fair Takaful Premium) satisfies.

**What it missed:** Billah is a Shariah scholar and lawyer, not an actuary or mathematician. He identifies the actuarial fairness requirement but does not derive the formula for computing the actuarially fair premium at r=0. That formula is our Theorem 2.

---

### Billah, M.M. (2023)
**"Actuarial valuation (pricing) of takaful products: A Malaysian experience"**
*Journal of Islamic Finance*, 12(2), 1–18.

**What it is:** More recent paper attempting to develop actuarial pricing formulas for takaful products in the Malaysian market context.

**Core finding:** Standard actuarial techniques (life tables, present value calculations) can be adapted for takaful pricing, but require modification because the conventional risk-free discount rate r cannot be used. Proposes using the "expected profit rate" of Shariah-compliant investments as a substitute discount rate.

**How it relates to us:** The "expected profit rate" substitute proposed by Billah 2023 is an ad hoc workaround to the same problem our κ-rate framework solves rigorously. He recognizes r cannot be used but his substitute lacks the no-arbitrage foundation that κ provides. We cite him to show the open problem his paper leaves, which our Theorem 2 closes.

**What it missed:** The substitute discount rate (expected profit rate) lacks a mathematical no-arbitrage proof. It is economically motivated but theoretically unsatisfying. No closed-form formulas. Does not connect to perpetual contract theory or stopping time framework.

---

### Htay, S.N.N., et al. (2012)
**"Accounting, Auditing and Governance for Takaful Operations"**
*John Wiley & Sons, Singapore*

**What it is:** Practitioner reference for takaful operations, governance, and accounting standards.

**Core finding:** Documents the operational and regulatory framework for takaful, including contribution calculation methodologies, surplus distribution rules, and AAOIFI Standard 26 compliance requirements.

**How it relates to us:** Provides the AAOIFI Standard 26 requirements that our takaful formula satisfies. The contribution calculation methodology described (contribution = expected claim payout, properly risk-adjusted) is exactly what our Theorem 2 computes.

**What it missed:** Operations manual, not a mathematical finance paper. No closed-form pricing formulas.

---

### Htay, S.N.N., & Salman, S.A. (2012)
**"Optimal pricing for participation in takaful"**
*Asian Social Science*, 8(7), 135–142.

**What it is:** Attempts to derive an optimal contribution formula for takaful participants — the closest precursor to our actuarial takaful pricing result.

**Core finding:** Proposes a contribution formula based on expected claims, but encounters a circularity: the discount factor requires a risk-free rate (which is riba), so the formula is self-referential. The paper does not resolve this circularity.

**How it relates to us:** This is the most direct predecessor of our Theorem 2. Htay-Salman arrive at the correct intuition (contribution = expected payout) but cannot execute it because they lack the no-arbitrage framework that sets r=0 without breaking the pricing theory. Our paper resolves their circularity exactly: at r=0 (ι=0), the expectation E[(K−X_τ)^+] is the contribution formula, with no discount factor needed, and the Ackerer no-arbitrage theorem guarantees its validity.

**What it missed:** The Ackerer framework (published 12 years later). The resolution of the circularity through the stopping time equivalence. This paper is the "why we are needed" citation.

---

### Abdallah, W., Maysami, R., & Shanmugam, B. (2022)
**"Actuarial model for takaful contributions via optimal retakaful"**
*Journal of Islamic Accounting and Business Research*, 13(5), 741–758.

**What it is:** Develops an optimization-based actuarial model for determining takaful contributions when retakaful (reinsurance) is available as a risk management tool.

**Core finding:** Takaful contributions can be optimized jointly with retakaful coverage ratios to minimize expected shortfall. The optimization uses actuarial loss models but requires a discount rate for present-value calculations.

**How it relates to us:** Cited in the takaful literature section to show the active research frontier in riba-free actuarial pricing. Our closed-form κ-rate formula provides the pricing foundation that their optimization-based approach uses as an input — if they plug in our κ-rate pricing formula, the circularity in their model is resolved.

**What it missed:** Uses a conventional discount rate despite the takaful context. The optimization is technically sophisticated but the underlying pricing formula is conventional. Our κ-rate provides the missing riba-free input.

---

## STRAND 7: Islamic Finance Risk Management

---

### Khan, T., & Ahmed, H. (2001)
**"Risk management: An analysis of issues in Islamic financial industry"**
*IRTI Occasional Paper No. 5, Islamic Development Bank, Jeddah*

**What it is:** Survey of risk management practices in Islamic financial institutions, documenting the structural gaps relative to conventional finance.

**Core finding:** Islamic institutions are "structurally under-hedged" — they cannot use standard credit derivatives (CDS, CDOs) to hedge credit risk because these instruments require interest-based pricing. This creates systemic vulnerability: Islamic banks hold concentrated credit exposures with no hedging tools.

**How it relates to us:** This is the foundational documentation of why the iCDS does not exist and why it is needed. Khan-Ahmed (2001) describe the $10T hedging gap that our iCDS framework (Section 6.3) begins to address. Cited in Introduction as the authority on the under-hedging problem.

**What it missed:** Documents the problem definitively but offers no mathematical solution. Written 23 years before the Ackerer framework that enables the solution.

---

### Khan, F. (2010)
**"How 'Islamic' is Islamic banking?"**
*Journal of Economic Behavior & Organization*, 76(3), 805–820.

**What it is:** Empirical and theoretical paper examining whether Islamic banks are genuinely different from conventional banks in their economic behavior, or merely relabeled conventional finance.

**Core finding:** Most Islamic banking products are economically equivalent to their conventional counterparts. The relabeling creates legal complexity and higher costs without genuine Islamic differentiation. Islamic banking as currently practiced is largely "Islamic in name only."

**How it relates to us:** Cited in the Introduction to establish the "cosmetic compliance" critique that our paper responds to. Our κ-rate framework is the mathematical alternative to cosmetic compliance — it produces genuine economic differentiation (r=0 really is different from r>0) grounded in proven no-arbitrage theory.

**What it missed:** Correctly identifies the problem but offers no solution. The mathematical alternative that Khan calls for is what our paper provides.

---

### Iqbal, M., & Molyneux, P. (2005)
**"Thirty Years of Islamic Banking: History, Performance, and Prospects"**
*Palgrave Macmillan, London*

**What it is:** Comprehensive history and performance analysis of Islamic banking from the 1970s through 2005.

**Core finding:** Islamic banking has grown substantially but faces fundamental challenges: absence of hedging instruments, reliance on murabahah (cost-plus sale) rather than genuine profit-sharing, and LIBOR-indexed pricing that undermines Shariah compliance.

**How it relates to us:** Historical context for the industry's persistent failure to develop genuine riba-free pricing tools. The 30-year timeline makes the "50-year impasse" in our opening paragraph concrete.

**What it missed:** Historical/institutional perspective with no mathematical content.

---

## STRAND 8: DeFi, Blockchain, and Islamic Finance

---

### Smolo, E., Hassan, M.K., & Paltrinieri, A. (2022)
**"Tokenization of sukuk: Ethereum case study"**
*Global Finance Journal*, 51, 100539.

**What it is:** Empirical study of sukuk tokenization on Ethereum, including a smart contract implementation of a Sukuk al-Murabaha and a cost-benefit analysis of tokenized vs. conventional issuance.

**Core finding:** Smart contracts on Ethereum can enforce the asset-backing requirement of AAOIFI Standard 17 at the protocol layer. Tokenized sukuk cost 1.95× less than conventional sukuk to issue. Blockchain transparency eliminates many gharar concerns.

**How it relates to us:** Provides the empirical basis for our claim (Remark in Section 6.1) that blockchain implementation makes the random redemption trigger transparent and independently verifiable, reducing gharar. The "protocol-layer enforcement" finding supports our argument that smart contracts can implement the κ-rate sukuk structure with lower transaction costs and higher transparency than legal wa'd documents.

**What it missed:** Tokenizes existing murabahah structures — does not propose new pricing methodologies. No connection to perpetual contract theory or riba-free pricing formulas. The pricing problem (SOFR-anchored issuance) remains unsolved in this paper.

---

### Meera, A.K.M., & Larbani, M. (2009)
**"Ownership effects of fractional reserve banking: An Islamic perspective"**
*Humanomics*, 25(2), 101–116.

**What it is:** Islamic economics paper arguing that fractional reserve banking violates Islamic ownership principles and proposing gold-backed digital monetary alternatives.

**Core finding:** The creation of money through credit expansion dilutes real ownership of existing money holders — an implicit transfer of wealth that has no Islamic justification. Proposes 100% reserve banking or gold-backed digital currencies as Islamic alternatives.

**How it relates to us:** Provides early Islamic finance thinking on digital/on-chain monetary alternatives. The "transparent ownership" principle Meera-Larbani argue for is implemented in our κ-rate sukuk: all pricing parameters are on-chain, ownership of the underlying asset is provable, and no fractional reserve creation occurs.

**What it missed:** Institutional monetary economics paper from 2009, before DeFi. Does not connect to perpetual contracts, stopping time theory, or no-arbitrage pricing.

---

## STRAND 9: Empirical Monetary Policy Evidence

---

### European Central Bank. (2019)
**"Is There a Zero Lower Bound? The Effects of Negative Policy Rates on Banks and Firms"**
*ECB Working Paper No. 2289*

**What it is:** Empirical analysis of the consequences of the ECB's negative interest rate policy (NIRP), examining how banks and firms responded to sub-zero policy rates from 2014 onwards.

**Core finding:** Credit markets continued to function when the ECB deposit rate fell to −0.1% (2014) and later −0.5% (2019). CDS spreads remained informative credit risk signals. Bond pricing remained coherent. The "zero lower bound" for deposit rates exists operationally (banks resist passing negative rates to retail depositors) but not for credit derivatives pricing.

**How it relates to us:** This is the natural experiment that empirically validates our Separation Theorem. If credit markets function at r < 0 (let alone r = 0), then r > 0 is demonstrably not necessary for credit pricing. The ECB experiment confirms empirically what we prove theoretically: interest and credit risk are separable. Cited in Section 3.4 (new section added in v2).

**What it missed:** The ECB paper's framing is purely monetary policy — it does not draw the Islamic finance implication. The observation that "credit pricing works at r≤0" is incidental to their monetary transmission analysis. The connection to riba-free pricing is ours.

---

### BIS. (2024)
**"OTC Derivatives Statistics at End-December 2023"**
*BIS Quarterly Review, March 2024*

**What it is:** The Bank for International Settlements' authoritative semi-annual survey of the global OTC derivatives market.

**Core finding:** Global CDS notional outstanding: approximately $10.1 trillion. Total OTC derivatives: $714 trillion notional. Credit derivatives are a small but critical segment for risk management.

**How it relates to us:** Cited in Section 6.3 for the $10T CDS market size — the scale of the credit protection market that has zero Islamic alternative. Our iCDS framework addresses this gap.

**What it missed:** Market statistics report. No pricing theory content.

---

## Summary Table

| Reference | Strand | What We Build On | What They Missed |
|---|---|---|---|
| Ackerer et al. (2024) | Perpetuals | ι=0 no-arb proof + RTR | Islamic finance + credit equivalence |
| Shiller (1993) | Perpetuals | Perpetuals as risk-sharing tool | Pricing formula at ι=0 |
| Jarrow-Turnbull (1995) | Credit | Intensity default modeling | r=0 viability |
| Duffie-Singleton (1999) | Credit | The isomorphic formula | r=0 pricing + Islamic finance |
| Duffie-Singleton (2003) | Credit | Full credit machinery | r=0 viability |
| Lando (1998) | Credit | Cox process treatment | ι=0 / Islamic finance |
| Bielecki-Rutkowski (2002) | Credit | Stochastic κ toolkit | Islamic finance + κ-rate |
| Elliott et al. (2000) | Credit | Filtration enlargement | Islamic finance |
| Jeanblanc et al. (2009) | Credit | CIR Laplace transform | Islamic finance + κ-rate |
| Jeanblanc-Rutkowski (2000) | Credit | Default time overview | Islamic finance |
| Duffie-Lando (2001) | Credit | Incomplete info spreads | r=0 + Islamic finance |
| Schönbucher (2003) | Credit | s=λ(1−δ) practitioner formula | r=0 → s=κ(1−δ) |
| Harrison-Kreps (1979) | Math | No-arb = EMM equivalence | Perpetuals + Islamic finance |
| Brémaud (1981) | Math | Point process compensator | Islamic finance application |
| Black-Scholes (1973) | Math | PDE structure | Perpetual payoffs at r=0 |
| CIR (1985) | Math | Mean-reverting intensity | κ as non-interest parameter |
| Protter (2005) | Math | Filtration setup | Islamic finance |
| El-Gamal (2006) | Islamic | Riba definition + critique | Mathematical solution |
| Usmani (2002) | Islamic | Riba typology | Pricing formula |
| Chapra (1985) | Islamic | κ-rate monetary vision | Mathematical implementation |
| Iqbal-Mirakhor (2011) | Islamic | Risk-sharing framework | Pricing formulas |
| Kamali (2007) | Islamic | Gharar/maysir criteria | Verification of criteria met |
| Kahf (1994) | Islamic | Opportunity cost argument | κ captures it without r |
| Siddiqi (2004) | Islamic | Genuineness requirement | Our framework satisfies it |
| SeekersGuidance (2025) | Islamic | ι=0 fatwa validation | Credit extension (future) |
| AAOIFI (2017) | Islamic | Compliance criteria | Pricing formulas |
| Khan-Abdallah (2017) | Sukuk | LIBOR ghost documented | κ-rate solution |
| Reboredo et al. (2021) | Sukuk | Spreads = credit-driven | Riba-free formula |
| Hassan et al. (2021) | Sukuk | Sukuk-bond co-integration | κ-rate alternative |
| Cakir-Raei (2007) | Sukuk | Sukuk ≈ Eurobond risk | κ-rate framework |
| Jobst (2007) | Sukuk | Form-over-substance critique | Mathematical solution |
| Jobst et al. (2008) | Sukuk | No sovereign Islamic benchmark | κ-yield curve |
| Adam-Thomas (2004) | Sukuk | wa'd legal mechanism | κ-rate pricing for wa'd |
| IIFM (2023) | Sukuk | $800B SOFR-anchored market | κ-rate alternative |
| IFSB (2024) | Sukuk | $3T industry, iCDS gap | iCDS pricing formula |
| Billah (2007) | Takaful | Tabarru structure | Actuarially fair formula |
| Billah-Masum (2023) | Takaful | Circularity with r | Our Theorem 2 resolves it |
| Htay et al. (2012) | Takaful | AAOIFI Standard 26 ops | Pricing formula |
| Htay-Salman (2012) | Takaful | Correct intuition, circular formula | κ-rate resolves circularity |
| Abdallah et al. (2022) | Takaful | Retakaful optimization | κ-rate as pricing input |
| Khan-Ahmed (2001) | Risk mgmt | Under-hedging documented | iCDS framework |
| Khan (2010) | Risk mgmt | Cosmetic compliance critique | Mathematical genuine alternative |
| Iqbal-Molyneux (2005) | Risk mgmt | 30-year history | κ-rate as structural solution |
| Smolo et al. (2022) | DeFi | On-chain enforcement of AAOIFI | κ-rate pricing layer |
| Meera-Larbani (2009) | DeFi | Transparent ownership principle | No-arb κ-rate implementation |
| ECB (2019) | Empirical | r≤0 markets function | Islamic finance implication |
| BIS (2024) | Empirical | $10T CDS market size | iCDS framework for that gap |

---

## Three Papers That Should Exist But Don't

These gaps represent the most important follow-on work from Paper 2:

**1. "The κ-Yield Curve: Empirical Estimation from Sukuk Panel Data"**
Should estimate κ values from a panel of sovereign and corporate sukuk, test whether κ-implied spreads explain observed yield spreads better than SOFR-based models, and build the first empirical κ-yield curve for the GCC and Malaysian sukuk markets.

**2. "Actuarial Properties of the κ-Rate Under Stochastic Hazard: CIR Applications to Agricultural Takaful in South Asia"**
Should test the stochastic-κ CIR takaful pricing formula against historical drought data in Bangladesh, Pakistan, and Indonesia — estimating κ from actuarial loss tables and verifying the closed-form premium formula.

**3. "An Islamic Credit Default Swap on Smart Contract Infrastructure: Design, Legal Analysis, and Initial Liquidity"**
Should take the iCDS pricing formula s* = κ(1−δ) and develop a complete implementation — smart contract architecture, legal wa'd documentation, regulatory analysis under VARA/MAS/BNM, and an initial liquidity bootstrapping mechanism using BRKX token incentives.

---

*File maintained by Shehzad Ahmed. Last updated: March 2026.*
*Location: /papers/paper2/literature_review.md*
