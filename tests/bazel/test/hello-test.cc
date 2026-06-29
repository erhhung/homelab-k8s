// https://google.github.io/googletest/
#include "gtest/gtest.h"
#include "main/hello-greet.h"

// https://google.github.io/googletest/primer.html#simple-tests
TEST(HelloTest, GetGreet) {
  EXPECT_EQ(get_greet("Bazel"), "Hello Bazel");
}
