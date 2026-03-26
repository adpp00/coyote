CXX      ?= g++
CXXFLAGS  = -O2 -std=c++17 -Wall

all: store_client read_client

store_client: store_client.cpp
	$(CXX) $(CXXFLAGS) -o $@ $<

read_client: read_client.cpp
	$(CXX) $(CXXFLAGS) -o $@ $<

clean:
	rm -f store_client read_client

.PHONY: all clean
