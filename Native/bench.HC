// Arithmetic loop used to compare native HolyC with emulated TempleOS.
// Sum of 0..19999999 is 199999990000000.
U0 Main()
{
  I64 i,n=0;
  F64 t0=tS;
  for (i=0;i<20000000;i++)
    n+=i;
  "BENCH loops=20000000 elapsed_s=%n sum=%d\n",tS-t0,n;
  // Exit status 0 when the sum is right. TRUE is 1 in HolyC, so a
  // mismatch is what we pass to ExitAiwnios.
  ExitAiwnios(n!=199999990000000);
}
Main;
