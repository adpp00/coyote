CXX      ?= g++
CXXFLAGS  = -O2 -std=c++17 -Wall

all: read_client store_client

read_client: read_client.cpp
	$(CXX) $(CXXFLAGS) -o $@ $<

store_client: store_client.cpp
	$(CXX) $(CXXFLAGS) -o $@ $<

clean:
	rm -f read_client store_client

.PHONY: all clean
