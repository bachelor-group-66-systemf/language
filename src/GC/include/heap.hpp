#pragma once

#include <list>
#include <stdlib.h>
#include <vector>

#include "chunk.hpp"
#include "profiler.hpp"

#define HEAP_SIZE 240240240
#define FREE_THRESH (uint)100
#define HEAP_DEBUG

namespace GC
{
	/**
	 * Flags for the collect overlead for conditional
	 * collection (mark/sweep/free/all).
	 */
	enum CollectOption
	{
		MARK = 1 << 0,
		SWEEP = 1 << 1,
		MARK_SWEEP = 1 << 2,
		FREE = 1 << 3,
		COLLECT_ALL = 0b1111 // all flags above
	};

	/**
	 * The heap class to represent the heap for the
	 * garbage collection. The heap is a singleton
	 * instance and can be retrieved by Heap::the()
	 * inside the heap class. The heap is represented
	 * by a char array of size 65536 and can enable
	 * a profiler to track the actions on the heap.
	 */
	class Heap
	{
	private:
		Heap() : m_heap(static_cast<char *>(malloc(HEAP_SIZE))) {}

		~Heap()
		{
			std::free((char *)m_heap);
		}

		char *const m_heap;
		size_t m_size{0};
		char *m_heap_top{nullptr};
		// static Heap *m_instance {nullptr};
		uintptr_t *m_stack_top{nullptr};
		bool m_profiler_enable{false};

		std::vector<Chunk *> m_allocated_chunks;
		std::vector<Chunk *> m_freed_chunks;
		std::list<Chunk *> m_free_list;

		static bool profiler_enabled();
		// static Chunk *get_at(std::vector<Chunk *> &list, size_t n);
		void collect();
		void sweep(Heap &heap);
		Chunk *try_recycle_chunks(size_t size);
		void free(Heap &heap);
		void free_overlap(Heap &heap);
		void mark(uintptr_t *start, const uintptr_t *end, std::vector<Chunk *> &worklist);
		void print_line(Chunk *chunk);
		void print_worklist(std::vector<Chunk *> &list);
		void mark_step(uintptr_t start, uintptr_t end, std::vector<Chunk *> &worklist);

		// Temporary
		Chunk *try_recycle_chunks_new(size_t size);
		void free_overlap_new(Heap &heap);

	public:
		/**
		 * These are the only five functions which are exposed
		 * as the API for LLVM. At the absolute start of the
		 * program the developer has to call init() to ensure
		 * that the address of the topmost stack frame is
		 * saved as the limit for scanning the stack in collect.
		 */

		static Heap &the();
		static void init();
		static void dispose();
		static void *alloc(size_t size);
		void set_profiler(bool mode);
		void set_profiler_log_options(RecordOption flags);

		// Stop the compiler from generating copy-methods
		Heap(Heap const &) = delete;
		Heap &operator=(Heap const &) = delete;

#ifdef HEAP_DEBUG
		void collect(CollectOption flags);		 // conditional collection
		void check_init();						 // print dummy things
		void print_contents();					 // print dummy things
		void print_allocated_chunks(Heap *heap); // print the contents in m_allocated_chunks
		void print_summary();
#endif
	};
}