# Export compliance — encryption classification and filings

> Status: living · Last verified: 2026-09-10 · [AI - claude-sonnet-5]

This doc is the sole owner of the export-compliance/encryption fact class for this repo. Other
docs (`apple-facts.md`, `CLAUDE.md`) link here and must not restate the reasoning below.

Confidence labels match `apple-facts.md`: **VERIFIED (source)** = read directly on a primary
source; **INFERRED** = reasoned from verified facts but not itself read on a primary source;
**UNVERIFIED (why)** = not confirmed on a primary source.

## The declaration

`ITSAppUsesNonExemptEncryption = true` is correct for pass-sumo. **VERIFIED.** Three independent
reasons, each of which alone settles it:

1. Apple's exemption list covers encryption "(a) specially designed for medical end-use; (b)
   limited to intellectual property and copyright protection; (c) limited to authentication,
   digital signature, or the decryption of data or files; (d) specially designed and limited for
   banking use or 'money transactions'; (e) limited to 'fixed' data compression or coding
   techniques." Exemption (c) covers **decryption** only; pass-sumo encrypts vault payload for
   confidentiality. VERIFIED (developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption).
2. The "platform crypto only" exemption does not apply. Apple, verbatim: "Typically, the use of
   encryption that's built into the operating system — for example, when your app makes HTTPS
   connections using URLSession — is exempt … whereas the use of proprietary encryption is not."
   pass-sumo ships its own Argon2/ChaCha20 implementations via the vendored KDBXKit. VERIFIED
   (developer.apple.com/documentation/security/complying-with-encryption-export-regulations).
3. Note 4 to Category 5, Part 2 of the EAR decontrols items whose *primary function* is not
   information security and whose crypto merely supports that primary function. A password
   manager's primary function **is** information security, so Note 4 does not apply. VERIFIED
   (bis.gov/learn-support/encryption-controls/decontrol; Federal Register document 2010-15072).

This cannot be downgraded to `false`.

## What Apple requires

VERIFIED, reproduced from developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption:

| Encryption algorithm in use | Required documentation |
|---|---|
| Your app uses encryption limited to that within the Apple operating system | No documentation required in App Store Connect. |
| Your app uses an industry standard algorithm, not provided within the Apple operating system | Upload your French encryption declaration in App Store Connect. |
| Your app uses proprietary encryption algorithms not accepted by international standard bodies (such as IEEE, IETF, or ITU) | Upload your: US CCATS + French encryption declaration |

Apple's footnote, verbatim: "French encryption declaration form is only required if you're
distributing your app on the App Store in France."

pass-sumo sits in the **middle row**: AES-256 (FIPS 197 / ISO), ChaCha20 (RFC 8439), Argon2 (RFC
9106), HMAC-SHA-256/512 and Salsa20 are all published, standards-body-accepted algorithms.
**Apple does not require a CCATS.** The only document is the French declaration, and only if
France is in the app's availability.

Apple's disclaimer, verbatim (developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance):
"it's your responsibility to review the Export Administration Regulation to determine whether your
app's use of encryption requires a formal classification (CCATS) from BIS. you're responsible for
all liabilities associated with misinterpretation of export regulations or claiming exemption
inaccurately."

Once Apple approves the documentation it issues a code for `ITSEncryptionExportComplianceCode`,
which stops the questionnaire reappearing at every submission. Apple states review takes
"approximately two business days" when the information is complete
(developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation).

## What BIS requires (independent of Apple)

**Classification: ECCN 5D992.c, mass market.** VERIFIED against EAR text. `§742.15(a)(1)`
verbatim: "Following classification or self-classification, items that meet the criteria of Note
3 to Category 5—Part 2 … (the 'mass market' note), are classified under ECCN 5A992 or 5D992 and are
no longer subject to this Section." Note 3's criteria (bis.gov/learn-support/encryption-controls/mass-market):
generally available to the public by being sold without restriction from stock at retail selling
points; the cryptographic functionality cannot be easily changed by the user; designed for
installation by the user without further substantial support. A Mac App Store app meets all three.

**No CCATS required.** `§740.17(b)(3)(ii)` requires a classification request only for items
performing "non-standard cryptography," which `§772.1` defines verbatim as "any implementation of
'cryptography' involving the incorporation or use of proprietary or unpublished cryptographic
functionality, including encryption algorithms or protocols that have not been adopted or approved
by a duly recognized international standards body (e.g., IEEE, IETF, ISO, ITU, ETSI, 3GPP, TIA, and
GSMA) and have not otherwise been published." pass-sumo's algorithms are all published and
standards-body-adopted, so it falls under `§740.17(b)(1)`, self-classification.

**Annual self-classification report IS required.** `§740.17(b)(1)` makes eligibility "subject to
submission of a self-classification report in accordance with §740.17(e)(3)." Mechanics from
`§740.17(e)(3)`:

- Recipients: `crypt-supp8@bis.doc.gov` and `enc@nsa.gov`. (The domain is `bis.doc.gov`, not
  `bis.gov`.)
- Subject line, verbatim: "Identify your email with subject 'self-classification report.'"
- Deadline, verbatim: "must be received … no later than February 1 the following year," covering
  the prior calendar year.
- Format: CSV only, 12 fields from `Supplement No. 8 to Part 742`: PRODUCT NAME, MODEL NUMBER,
  MANUFACTURER, ECCN, AUTHORIZATION TYPE, ITEM TYPE, SUBMITTER NAME, TELEPHONE NUMBER, E-MAIL
  ADDRESS, MAILING ADDRESS, NON-U.S. COMPONENTS, NON-U.S. MANUFACTURING LOCATIONS. No field may be
  blank. AUTHORIZATION TYPE is `MMKT` for mass market.
- If nothing changed from the previous year, an email saying so suffices. If there were no exports
  in the year, no report is due.

EAR quotations VERIFIED against the eCFR text as retrieved 2026-09-09.

## The Apple/BIS discrepancy

Apple's help text states: "(If you use non-exempt encryption and provide documentation to Apple,
the self-classification report isn't necessary.)" **This is wrong for pass-sumo.** BIS states,
verbatim (bis.gov/learn-support/encryption-controls/annual-self-classification): "An annual
self-classification report is a requirement for items exported under License Exception ENC -
740.17(b)(1), UNLESS a Commodity Classification (CCATS) has been submitted for the item." The
waiver is conditioned on a CCATS, and pass-sumo will not file one because none is required. The
"documentation provided to Apple" is the French declaration, which is not a CCATS. **Conclusion:
the BIS annual report obligation stands.** This doc sides with the primary BIS text over Apple's
simplification.

## Developer location does not change this

Apple, verbatim (developer.apple.com/documentation/security/complying-with-encryption-export-regulations):
"When you submit your app to TestFlight or the App Store, you upload your app to a server in the
United States. If you distribute your app outside the U.S. or Canada, your app is subject to U.S.
export laws, regardless of where your legal entity is based." VERIFIED.

## France

Apple, verbatim: "The import and export of encryption apps distributed in France are also
controlled by the French Government. The main items of control for France are Secure Storage,
Secure Communications, and Security Anti-Virus applications. Exemptions include Banking and
Medical applications." A password manager is Secure Storage, so the declaration applies if France
is in availability.

Under French law the regime is *déclaration*, not *autorisation*. ANSSI, verbatim
(cyber.gouv.fr/reglementation/reglementation-identite-confiance-numerique/controles-reglementaires-cryptographie/controle-moyen-de-cryptologie/):
"L'utilisation d'un moyen de cryptologie est libre… En revanche, la fourniture, l'importation, le
transfert intracommunautaire et l'exportation d'un moyen de cryptologie sont soumis, sauf
exception, à déclaration ou à demande d'autorisation." Submission address `controle@ssi.gouv.fr`,
subject format `[formalités] <marque> – <nom du produit>`. ANSSI's stated norm is one month for a
déclaration, four months for an autorisation.

**Recommendation, not a decision already taken:** excluding France from availability at first
release collapses the Apple requirement to "no documentation required" and defers the ANSSI work
entirely. France can be added later as its own step.

The current ANSSI submission flow is **UNVERIFIED** — the detailed indie account available
(cryptomator.org/blog/2016/06/16/indepth-french-app-store/, describing a paper form and roughly
two months to approval) predates the electronic process; the current form and steps were not
confirmed against a live ANSSI page.

## What is NOT required

- **No CCATS** (see above).
- **No ERN / encryption registration.** That regime was eliminated by the final rule at 81 FR
  64656, effective 2016-09-20 (bis.doc.gov/index.php/documents/new-encryption/1650-81-fr-64656-wa15-rule-2016-21544).
  VERIFIED. Any guidance recommending an ERN predates that rule.
- **No `§742.15(b)(2)` source-code notification.** Required only for non-standard cryptography.
  Separately, `§742.15(b)(1)` verbatim: "publicly available … encryption source code classified
  under ECCN 5D002 is not subject to the EAR. Such source code is publicly available even if it is
  subject to an express agreement for the payment of a licensing fee or royalty for commercial
  production or sale of any product developed using the source code." This decontrols **published
  source code**, not the compiled binary distributed through the App Store, so it does not remove
  any obligation above.

## Open items

- The exact ITEM TYPE string for the CSV, chosen from the list in `Supplement No. 8 to Part 742
  (a)(6)` — that list was not retrieved. UNVERIFIED. Settle by opening Supplement No. 8 before the
  first filing.
- Which party is the "exporter" for `§740.17(e)(3)` purposes when the developer is not a US
  person. UNVERIFIED — a question for a lawyer, not for documentation.
- The current ANSSI déclaration flow and form (see France above). UNVERIFIED.
- Whether an independent Russian obligation exists. Apple's current export-compliance
  documentation does not mention Russia at all; no independent requirement was located.
  UNVERIFIED, and moot unless Russia is in availability.
