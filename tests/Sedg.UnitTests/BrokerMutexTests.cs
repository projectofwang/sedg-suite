using Sedg.Broker;

/// <summary>Single-holder behavior of the Local\Sedg.Broker mutex; release in finally.</summary>
public static class BrokerMutexTests
{
    [Test]
    public static void SecondHolderIsRejectedUntilRelease()
    {
        var first = new BrokerMutex();
        var second = new BrokerMutex();
        try
        {
            Assert.True(first.TryEnter());
            Assert.False(second.TryEnter());
        }
        finally
        {
            first.Exit();
            second.Exit();
        }

        Assert.True(first.TryEnter());
        try
        {
            Assert.True(second.TryEnter() is false);
        }
        finally
        {
            first.Exit();
        }
    }

    [Test]
    public static void ExitIsIdempotent()
    {
        var mutex = new BrokerMutex();
        mutex.Exit();
        mutex.Exit();
        Assert.True(mutex.TryEnter());
        try
        {
            Assert.True(mutex.TryEnter() is false);
        }
        finally
        {
            mutex.Exit();
        }
    }
}
