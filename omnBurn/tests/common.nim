## Helpers shared by the hash and CLI tests.

import ../src/omnburn/hash

proc hexBytes*(s: string): seq[byte] = decodeBase16(s)[1]
proc b64Bytes*(s: string): seq[byte] = decodeBase64(s, urlSafe = false)[1]

const sha384b64* = "EVSTQN3/azprG1Anm3QDgpJLIm9Nao0Yz1ztcQTwFspd3yD65VohhpuuCOmLASjC"
