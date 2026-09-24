import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/api_keys.dart';

class GPTService {
  static Future<Map<String, dynamic>> sendToGPT(String englishText) async {
    return await analyzeTransaction(englishText);
  }

  static Future<Map<String, dynamic>> analyzeTransaction(String text) async {
    final url = Uri.parse("https://api.openai.com/v1/chat/completions");

    final prompt =
        """
You are an intent and amount extraction system for a digital khata book
used by idol makers in Kolkata.
You are working for an idol-maker finance app.

CRITICAL BACKWARD COMPATIBILITY REQUIREMENT:
Your output MUST ALWAYS follow the LEGACY JSON schema exactly as described below.
- Do NOT add extra keys.
- Do NOT change key names.
- Do NOT output additional commentary.
- Output ONLY JSON.
If the input is ambiguous, choose intent=\"unknown\" (or a best-fit legacy intent) but still keep schema.

INPUT CHARACTERISTICS:
The input is an English sentence translated from Bengali voice dictation. Expect informal phrasing,
translation noise, and domain words.

NORMALIZATION RULES (MANDATORY):
Treat the following words as the SAME worker_type (case-insensitive):

  painting:
    paint, painting, color, colour, rang, rang kora, paint work, colouring, or any other close synonyms

  clay:
    clay, mati, modeling, modelling, clay modeling, clay modelling, murti gora, clay work, or any other close synonyms

  structure:
    bamboo, kathamo, structure, frame, wood work, or any other close synonyms

IMPORTANT:
- These normalization rules are for detecting the worker domain.
- HOWEVER, the LEGACY OUTPUT worker_type enum is LIMITED (see below). You must map:
    painting -> \"painting\"
    clay -> \"clay\"
    structure -> \"other\"   (because \"structure\" is NOT an allowed worker_type in the legacy output enum)
- Do NOT output \"other\" if painting/clay synonyms match.
- If worker_type is inferred using these rules, confidence must be >= 0.8 (ONLY for worker_payment intent).

ALLOWED worker_type values in LEGACY OUTPUT (must follow exactly):
\"clay\", \"painting\", \"decoration\", \"transport\", \"other\"

PERSON INCOME RULE (MANDATORY):
If money is received from a PERSON NAME and no samiti/order keywords are present,
classify as:
{
  \"intent\": \"income\",
  \"amount\": number,
  \"category\": \"other\"
}
Person names are NOT samiti unless words like \"samiti\", \"committee\", \"puja\", or \"association\" appear.

SAMITI KEYWORDS (non-exhaustive):
samiti, committee, puja, association, club, sangha, mandal

ORDER / CLIENT PAYMENT CLUES (non-exhaustive):
order, booking, advance, token, final, due, rest money, balance, installment, payment for idol, murti order,
\"for Durga\", \"for Kali\", \"for Ganesh\", etc.
If it is clearly money received for an idol order, prefer intent=\"order_payment\" unless PERSON INCOME RULE overrides.

Supported intents (legacy):
income: general income received
expense: general expense paid
samiti_fund: money received from a samiti (organization/committee)
worker_payment: payment made to a worker
order_payment: payment received for an order
unknown: cannot determine intent

LEGACY OUTPUT FORMATS (MANDATORY)

A) For worker_payment intent, you MUST return EXACTLY:
{
  \"intent\": \"worker_payment\",
  \"amount\": number,
  \"worker_name\": string | null,
  \"worker_type\": one of [\"clay\", \"painting\", \"decoration\", \"transport\", \"other\"],
  \"idol_type\": one of [\"durga\", \"ganesh\", \"saraswati\", \"lakshmi\", \"unknown\"],
  \"confidence\": number between 0 and 1
}

B) For ALL OTHER intents, return EXACTLY:
{
  \"intent\": \"income\" | \"expense\" | \"samiti_fund\" | \"order_payment\" | \"unknown\",
  \"amount\": number (0 if none),
  \"category\": \"samiti\" | \"worker\" | \"material\" | \"transport\" | \"other\" | null
}

IMPORTANT RULES (MANDATORY):
- Output ONLY JSON.
- Never guess amounts. If no amount is present:
    - For worker_payment: set amount to 0 (legacy expects a number; do not use null)
    - For other intents: set amount to 0
- If a field is not clearly mentioned, return null instead of guessing:
    - worker_name: null if not explicitly present
    - idol_type: \"unknown\" unless explicitly mentioned as durga/ganesh/saraswati/lakshmi
- For worker_payment: extract worker_name, worker_type, and idol_type only if explicitly mentioned,
  EXCEPT worker_type may be inferred via NORMALIZATION RULES (then confidence must be >= 0.8).
- category mapping for non-worker intents:
    - samiti_fund -> category \"samiti\"
    - expense due to buying materials -> category \"material\"
    - expense due to transport/tempo/fuel -> category \"transport\"
    - any worker-related but not worker_payment -> category \"worker\" (rare; prefer worker_payment when paying a worker)
    - otherwise -> \"other\"
- confidence is ONLY allowed in worker_payment output. Do not include confidence for other intents.

DISAMBIGUATION GUIDANCE:
- If sentence indicates paying someone to do work (paid/gave money to worker/painter/clay man), use worker_payment.
- If sentence indicates buying items (bought/purchased/paid shop for paint/clay/bamboo), use expense with category \"material\".
- If sentence indicates received from samiti/committee/puja association, use samiti_fund.
- If sentence indicates received for an idol/order (advance/final/balance for Durga idol), use order_payment.
- If it is received from a person name but no samiti/order words, PERSON INCOME RULE applies -> income, category other.
- If truly unclear -> unknown, amount 0, category null.

Examples:

Input: \"Paid 100 rupees to Ramesh in clay\"
Output:
{
  \"intent\": \"worker_payment\",
  \"amount\": 100,
  \"worker_name\": \"Ramesh\",
  \"worker_type\": \"clay\",
  \"idol_type\": \"unknown\",
  \"confidence\": 0.92
}

Input: \"Received 5000 from Behala Samity\"
Output:
{
  \"intent\": \"samiti_fund\",
  \"amount\": 5000,
  \"category\": \"samiti\"
}

Input: \"Bought paint for 2000\"
Output:
{
  \"intent\": \"expense\",
  \"amount\": 2000,
  \"category\": \"material\"
}

Now extract from this input:
$text
""";

    final response = await http.post(
      url,
      headers: {
        "Content-Type": "application/json",
        "Authorization": "Bearer ${ApiKeys.openAI}",
      },
      body: jsonEncode({
        "model": "gpt-4o-mini",
        "messages": [
          {"role": "user", "content": prompt},
        ],
        "temperature": 0,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception("GPT error: ${response.body}");
    }

    final data = jsonDecode(response.body);
    final content = data["choices"][0]["message"]["content"];

    return jsonDecode(content);
  }
}
