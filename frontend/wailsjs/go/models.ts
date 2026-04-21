export namespace ingest {
	
	export class Source {
	    url: string;
	    type: string;
	    tags: string[];
	    name?: string;
	
	    static createFrom(source: any = {}) {
	        return new Source(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.url = source["url"];
	        this.type = source["type"];
	        this.tags = source["tags"];
	        this.name = source["name"];
	    }
	}

}

export namespace library {
	
	export class ReportMeta {
	    filename: string;
	    source_file: string;
	    source_url: string;
	    generated_at: string;
	    model: string;
	    intentions_used: boolean;
	    tags?: string[];
	
	    static createFrom(source: any = {}) {
	        return new ReportMeta(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.filename = source["filename"];
	        this.source_file = source["source_file"];
	        this.source_url = source["source_url"];
	        this.generated_at = source["generated_at"];
	        this.model = source["model"];
	        this.intentions_used = source["intentions_used"];
	        this.tags = source["tags"];
	    }
	}

}

export namespace main {
	
	export class AnalysisResult {
	    processedCount: number;
	    error?: string;
	
	    static createFrom(source: any = {}) {
	        return new AnalysisResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.processedCount = source["processedCount"];
	        this.error = source["error"];
	    }
	}
	export class ChatMessage {
	    role: string;
	    content: string;
	
	    static createFrom(source: any = {}) {
	        return new ChatMessage(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.role = source["role"];
	        this.content = source["content"];
	    }
	}
	export class DocumentInfo {
	    filename: string;
	    path: string;
	    date: string;
	    sourceUrl: string;
	    name: string;
	
	    static createFrom(source: any = {}) {
	        return new DocumentInfo(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.filename = source["filename"];
	        this.path = source["path"];
	        this.date = source["date"];
	        this.sourceUrl = source["sourceUrl"];
	        this.name = source["name"];
	    }
	}
	export class FullPipelineResult {
	    ingested: number;
	    analyzed: number;
	    error?: string;
	
	    static createFrom(source: any = {}) {
	        return new FullPipelineResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.ingested = source["ingested"];
	        this.analyzed = source["analyzed"];
	        this.error = source["error"];
	    }
	}
	export class IngestResult {
	    savedCount: number;
	    error?: string;
	
	    static createFrom(source: any = {}) {
	        return new IngestResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.savedCount = source["savedCount"];
	        this.error = source["error"];
	    }
	}
	export class MemoryEntry {
	    index: number;
	    createdAt: string;
	    text: string;
	
	    static createFrom(source: any = {}) {
	        return new MemoryEntry(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.index = source["index"];
	        this.createdAt = source["createdAt"];
	        this.text = source["text"];
	    }
	}
	export class OrchestratorStatus {
	    phase: string;
	    queueDepth: number;
	    activeJob: string;
	    completedJobs: number;
	    failedJobs: number;
	
	    static createFrom(source: any = {}) {
	        return new OrchestratorStatus(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.phase = source["phase"];
	        this.queueDepth = source["queueDepth"];
	        this.activeJob = source["activeJob"];
	        this.completedJobs = source["completedJobs"];
	        this.failedJobs = source["failedJobs"];
	    }
	}
	export class PendingFile {
	    filename: string;
	    path: string;
	    date: string;
	
	    static createFrom(source: any = {}) {
	        return new PendingFile(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.filename = source["filename"];
	        this.path = source["path"];
	        this.date = source["date"];
	    }
	}
	export class ProviderInfo {
	    name: string;
	    type: string;
	    baseUrl: string;
	    model: string;
	    active: boolean;
	    hasKey: boolean;
	
	    static createFrom(source: any = {}) {
	        return new ProviderInfo(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.name = source["name"];
	        this.type = source["type"];
	        this.baseUrl = source["baseUrl"];
	        this.model = source["model"];
	        this.active = source["active"];
	        this.hasKey = source["hasKey"];
	    }
	}

}

export namespace orchestrator {
	
	export class QueueEntry {
	    filename: string;
	    path: string;
	    status: string;
	
	    static createFrom(source: any = {}) {
	        return new QueueEntry(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.filename = source["filename"];
	        this.path = source["path"];
	        this.status = source["status"];
	    }
	}

}

