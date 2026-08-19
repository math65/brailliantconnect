// This file is intentionally empty.
//
// A File Provider extension is an executable: it needs an entry point. Without
// this file, the binary is produced with no bootstrap the system can use, and
// the system is then unable to instantiate the principal class — it answers
// "Extension not registered" (FP -2014), then providerNotFound.
//
// Apple's sample project does exactly the same.
