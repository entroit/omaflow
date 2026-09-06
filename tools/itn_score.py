"""Independent ordered numeric comparison, allowing unchanged spoken forms.

The corpus reference mixes digits and words. Normalize both before comparison;
partial conversion is neither an invention nor permission to lose a value.
This is a scoring aid, not a general speech normalization engine.
"""
import re
import unicodedata

SMALL = dict(zip("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split(), range(20)))
SMALL.update({"o": 0, "oh": 0})
TENS = dict(zip("twenty thirty forty fifty sixty seventy eighty ninety".split(), range(20, 100, 10)))
SCALES = {"hundred": 100, "thousand": 1000, "million": 1000000, "billion": 1000000000}
ORDINALS = dict(zip("first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth thirteenth fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth".split(), range(1, 20)))
ORDINALS.update(dict(zip("twentieth thirtieth fortieth fiftieth sixtieth seventieth eightieth ninetieth hundredth thousandth".split(), [20,30,40,50,60,70,80,90,100,1000])))


def ordered_digits(text):
    text = unicodedata.normalize("NFKD", text)
    tokens = re.findall(r"\d+|[a-z]+", text.lower())
    values = []
    current = None
    previous = None
    for token in tokens + [""]:
        ordinal = ORDINALS.get(token.removesuffix("s"))
        value = SMALL.get(token, TENS.get(token, SCALES.get(token, ordinal)))
        if token in ("quarter", "quarters", "half", "halves"):
            if current is not None:
                values.append(str(current))
            values.append("4" if token.startswith("quarter") else "2")
            current = previous = None
        elif token in ("and",) and current is not None and current >= 100:
            continue
        elif value is not None:
            if value >= 100:
                current = max(1, current or 0) * value
            elif current is None:
                current = value
            elif (value < 10 and previous in TENS.values()) or current % 100 == 0:
                current += value
            else:
                values.append(str(current))
                current = value
            previous = value
        else:
            if current is not None:
                values.append(str(current))
            current = previous = None
            if token.isdigit():
                values.append(token)
    return "".join(values)
