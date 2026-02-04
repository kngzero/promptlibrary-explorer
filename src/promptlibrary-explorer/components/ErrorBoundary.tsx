import React from 'react';

interface ErrorBoundaryState {
    hasError: boolean;
    message: string | null;
}

class ErrorBoundary extends React.Component<React.PropsWithChildren, ErrorBoundaryState> {
    constructor(props: React.PropsWithChildren) {
        super(props);
        this.state = { hasError: false, message: null };
    }

    static getDerivedStateFromError(error: Error): ErrorBoundaryState {
        return { hasError: true, message: error?.message || 'Unexpected error' };
    }

    componentDidCatch(error: Error, info: React.ErrorInfo) {
        console.error('App crashed:', error, info);
    }

    handleReload = () => {
        this.setState({ hasError: false, message: null });
        window.location.reload();
    };

    render() {
        if (this.state.hasError) {
            return (
                <div className="h-screen w-screen bg-zinc-900 text-white flex flex-col items-center justify-center px-6 text-center gap-4">
                    <div className="text-2xl font-semibold">Something went wrong.</div>
                    <div className="text-sm text-zinc-400 max-w-lg">
                        {this.state.message || 'An unexpected error occurred. Try reloading the app.'}
                    </div>
                    <div className="flex gap-3">
                        <button
                            onClick={this.handleReload}
                            className="px-4 py-2 rounded-md bg-fuchsia-600 hover:bg-fuchsia-700 text-white font-semibold"
                        >
                            Reload
                        </button>
                        <button
                            onClick={() => this.setState({ hasError: false })}
                            className="px-4 py-2 rounded-md border border-zinc-600 text-zinc-200 hover:bg-zinc-800"
                        >
                            Dismiss
                        </button>
                    </div>
                </div>
            );
        }
        return this.props.children;
    }
}

export default ErrorBoundary;
