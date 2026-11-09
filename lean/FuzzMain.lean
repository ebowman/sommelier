import Sommelier.Fuzz
-- `lake exe fuzz`: the entry point lives here so that other executables (`fixture`) can import `Sommelier.Fuzz` for its generators without clashing on `main`.
def main (args : List String) : IO UInt32 := fuzzMain args
